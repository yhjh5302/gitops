#!/usr/bin/env bash
# Kubernetes 핵심 시스템 이미지를 로컬 사설 레지스트리로 동기화하는 스크립트

set -euo pipefail

# 스크립트 위치 기준 설정
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# config.sh 환경변수 파일 로드
if [ -f "${SCRIPT_DIR}/config.sh" ]; then
  source "${SCRIPT_DIR}/config.sh"
fi

# config.sh 환경변수 로드
K8S_VER="${KUBERNETES_VERSION:-v1.35}"
REGISTRY="${IMAGE_REPOSITORY:-registry.k8s.io}"
SANDBOX_IMG="${SANDBOX_IMAGE:-registry.k8s.io/pause:3.10.2}"

# nerdctl 작동 확인
if ! command -v nerdctl &> /dev/null; then
  echo "오류: 이 작업을 수행하려면 nerdctl이 설치되어 있고 containerd가 실행 중이어야 합니다."
  exit 1
fi

echo "============================================================="
echo "Kubernetes 핵심 시스템 이미지를 로컬 사설 레지스트리로 푸시합니다."
echo "Target K8s Version: ${K8S_VER}"
echo "Target Registry: ${REGISTRY}"
echo "============================================================="

# 1. kubeadm을 통해 필요한 원본 이미지 목록 획득
if ! command -v kubeadm &> /dev/null; then
  echo "❌ 오류: 이 스크립트는 kubeadm이 설치되어 있어야 실행할 수 있습니다. 4번 메뉴를 먼저 수행하십시오."
  exit 1
fi

raw_images=$(kubeadm config images list --kubernetes-version="${K8S_VER}" 2>/dev/null || echo "")
if [ -z "$raw_images" ]; then
  echo "❌ 오류: kubeadm config images list 명령 실행에 실패했거나 빈 결과를 반환했습니다."
  echo "지정한 Kubernetes 버전(${K8S_VER})의 유효성 및 인터넷 연결을 확인해 주세요."
  exit 1
fi

IMAGES=()
while read -r img; do
  if [ -n "$img" ]; then
    clean_img="${img#registry.k8s.io/}"
    IMAGES+=("$clean_img")
  fi
done <<< "$raw_images"

# Harbor 주소 추출 및 퍼블릭 감지
harbor_domain=$(echo "$REGISTRY" | cut -d'/' -f1)

IS_PUBLIC_REGISTRY=false
if [ "$harbor_domain" = "registry.k8s.io" ] || [ "$harbor_domain" = "docker.io" ] || [ "$harbor_domain" = "quay.io" ] || [ -z "$harbor_domain" ]; then
  IS_PUBLIC_REGISTRY=true
fi

# 2. 감지된 pause 이미지 버전을 config.sh 에 자동 동기화 업데이트 (사설 레지스트리를 사용할 때만 보정)
if [ "$IS_PUBLIC_REGISTRY" = "false" ]; then
  pause_line=$(echo "$raw_images" | grep "/pause:" | head -n 1 || echo "")
  if [ -n "$pause_line" ]; then
    detected_pause="${pause_line#registry.k8s.io/}"
    new_sandbox_image="${REGISTRY}/${detected_pause}"
    
    config_file="${SCRIPT_DIR}/config.sh"
    if [ -f "$config_file" ]; then
      sed -i "s|^export SANDBOX_IMAGE=.*|export SANDBOX_IMAGE=\"${new_sandbox_image}\"|g" "$config_file"
      echo "-> [동기화] config.sh 내 SANDBOX_IMAGE를 ${new_sandbox_image} 로 업데이트했습니다."
    fi
  fi
fi

echo "확인된 푸시 대상 핵심 이미지 목록:"
for img in "${IMAGES[@]}"; do
  echo " - registry.k8s.io/${img}"
done

echo ""
read -p "사설 레지스트리(${REGISTRY})로 이미지 동기화(Pull -> Tag -> Push)를 진행하시겠습니까? (y/N): " choice
if [[ ! "$choice" =~ ^[Yy]$ ]]; then
  echo "동기화 작업을 취소했습니다."
  exit 0
fi

LOGGED_IN=false
user_home_dir=""

if [ "$IS_PUBLIC_REGISTRY" = "true" ]; then
  echo "-> 공식 퍼블릭 레지스트리(${harbor_domain:-registry.k8s.io}) 사용이 감지되었습니다. 로그인 검사를 생략합니다."
  LOGGED_IN=true
else
  echo "사설 레지스트리(${harbor_domain}) 로그인 상태를 확인 중..."
  
  if [ -n "${SUDO_USER:-}" ]; then
    user_home_dir=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  else
    user_home_dir="$HOME"
  fi
  
  # 1) 일반 유저 config.json 검사 (docker & nerdctl)
  if [ -f "${user_home_dir}/.docker/config.json" ] && grep -q "${harbor_domain}" "${user_home_dir}/.docker/config.json"; then
    LOGGED_IN=true
  elif [ -f "${user_home_dir}/.config/nerdctl/config.json" ] && grep -q "${harbor_domain}" "${user_home_dir}/.config/nerdctl/config.json"; then
    LOGGED_IN=true
  fi
  # 2) root/sudo 유저 config.json 검사 (docker & nerdctl) - sudo 권한 사용
  if sudo test -f "/root/.docker/config.json" && sudo grep -q "${harbor_domain}" "/root/.docker/config.json"; then
    LOGGED_IN=true
  elif sudo test -f "/root/.config/nerdctl/config.json" && sudo grep -q "${harbor_domain}" "/root/.config/nerdctl/config.json"; then
    LOGGED_IN=true
  fi
  
  if [ "$LOGGED_IN" = "false" ]; then
    echo "⚠️ 사설 레지스트리 로그인 정보가 감지되지 않았습니다."
    echo "로그인을 먼저 진행해 주세요:"
    sudo nerdctl login "$harbor_domain" || {
      echo "❌ 사설 레지스트리 로그인 실패! 작업을 중단합니다."
      exit 1
    }
  else
    echo "-> 이미 ${harbor_domain} 에 로그인되어 있습니다. (인증 정보 확인 완료)"
  fi
fi

if [ "$IS_PUBLIC_REGISTRY" = "false" ]; then
  # containerd certs.d hosts.toml 동기화 로직 추가 - sudo 권한으로 실행하여 권한 오류 예방
  echo "-> containerd 사설 레지스트리 인증 연동 설정을 검사 및 동기화합니다..."
  auth_token=$(sudo python3 -c "
import json, os, sys
paths = [
    '/root/.config/nerdctl/config.json',
    '${user_home_dir}/.config/nerdctl/config.json',
    '/root/.docker/config.json',
    '${user_home_dir}/.docker/config.json'
]
for p in paths:
    if os.path.exists(p):
        sys.stderr.write(f'  [Debug Parser] 파일 검사: {p}\n')
        try:
            with open(p) as f:
                data = json.load(f)
                auths = data.get('auths', {})
                sys.stderr.write(f'  [Debug Parser] 발견된 도메인 목록: {list(auths.keys())}\n')
                if '${harbor_domain}' in auths:
                    auth = auths['${harbor_domain}'].get('auth', '')
                    if auth:
                        print(auth)
                        sys.stderr.write(f'  ✓ [Debug Parser] {p} 에서 ${harbor_domain} 자격증명을 추출했습니다.\n')
                        break
        except Exception as e:
            sys.stderr.write(f'  [Debug Parser] 에러 ({p}): {e}\n')
            pass
")
  auth_token=$(echo "$auth_token" | tr -d '\r\n[:space:]')

  if [ -n "$auth_token" ]; then
    sudo mkdir -p "/etc/containerd/certs.d/${harbor_domain}"
    sudo tee "/etc/containerd/certs.d/${harbor_domain}/hosts.toml" > /dev/null <<EOF
server = "https://${harbor_domain}"

[host."https://${harbor_domain}"]
  capabilities = ["pull", "resolve"]

  [host."https://${harbor_domain}".header]
    Authorization = "Basic $auth_token"
EOF
    echo "-> [동기화] containerd 레지스트리(/etc/containerd/certs.d/${harbor_domain}/hosts.toml) 인증 파일을 갱신했습니다."
    echo "-> containerd 서비스를 재시작합니다..."
    sudo systemctl daemon-reload
    sudo systemctl restart containerd
  else
    echo "⚠️ 경고: Docker config.json에서 인증 토큰을 추출하지 못했습니다. containerd 연동을 건너뜁니다."
  fi
fi

# Harbor에 이미 해당 이미지가 올라가 있는지 API를 통해 확인하는 함수
check_image_exists_in_harbor() {
  local img_path="$1"
  local img_tag="$2"
  local api_url="https://${harbor_domain}/v2/${img_path}/manifests/${img_tag}"
  local http_status
  local accept_headers="Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json"
  
  if [ -n "${auth_token:-}" ]; then
    http_status=$(curl -s -k -o /dev/null -I -w "%{http_code}" \
      -H "Authorization: Basic ${auth_token}" \
      -H "${accept_headers}" \
      "$api_url" || echo "000")
  else
    http_status=$(curl -s -k -o /dev/null -I -w "%{http_code}" \
      -H "${accept_headers}" \
      "$api_url" || echo "000")
  fi
  
  # HTTP 응답 결과 화면 출력 (사용자 디버그 돕기용)
  echo "    [Registry Check] HTTP Status: $http_status (Auth: $([ -n "${auth_token:-}" ] && echo "OK" || echo "NONE"))"
  
  if [ "$http_status" = "200" ]; then
    return 0
  else
    return 1
  fi
}

if [ "$IS_PUBLIC_REGISTRY" = "false" ]; then
  echo "-> 사설 레지스트리로 이미지 Push 작업을 진행합니다..."
  for img in "${IMAGES[@]}"; do
    src_img="registry.k8s.io/${img}"
    dest_img="${REGISTRY}/${img}"
    
    img_name="${img%%:*}"
    img_tag="${img##*:}"
    check_path="registry.k8s.io/${img_name}"
    
    echo -e "\n[Syncing] ${src_img} -> ${dest_img}"
    
    # 사설 레지스트리 존재 여부 조회
    if check_image_exists_in_harbor "$check_path" "$img_tag"; then
      echo " -> ✓ [Skip] 이미 사설 레지스트리에 존재합니다. 동기화를 건너뜁니다."
      continue
    fi
    
    echo " -> Pulling..."
    sudo nerdctl rmi -f "$src_img" "$dest_img" &>/dev/null || true
    sudo nerdctl pull --all-platforms "$src_img"
    
    echo " -> Tagging..."
    sudo nerdctl tag "$src_img" "$dest_img"
    
    echo " -> Pushing..."
    sudo nerdctl push --all-platforms "$dest_img"
    
    # 로컬 디스크 절약을 위한 태그 정리
    echo " -> Cleaning local tags..."
    sudo nerdctl rmi "$src_img" "$dest_img" || true
  done
else
  echo "-> 공식 퍼블릭 레지스트리를 사용하므로 로컬 OCI Push 루프를 건너뜁니다."
fi

echo -e "\n============================================================="
echo "-> Harbor에서 containerd k8s.io 네임스페이스로 이미지 pre-pull 진행 중..."
echo "============================================================="

echo " -> Pulling system images via kubeadm..."
sudo kubeadm config images pull --image-repository "$REGISTRY" --kubernetes-version "$K8S_VER" --cri-socket unix:///run/containerd/containerd.sock

echo -e "\n============================================================="
echo "✓ 사설 레지스트리 이미지 동기화 및 Local k8s.io 캐싱 완료!"
echo "⚠️ 중요: Harbor의 'registry.k8s.io' 프로젝트 Access Level이"
echo "  'Public'으로 설정되어 있거나, containerd에 인증 정보가 설정되었는지 확인하세요."
echo "============================================================="
