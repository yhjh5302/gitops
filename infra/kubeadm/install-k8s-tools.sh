#!/usr/bin/env bash

set -euo pipefail

# root 권한 체크
if [ "$EUID" -ne 0 ]; then
  echo "오류: 이 스크립트는 root 권한(sudo)으로 실행해야 합니다."
  exit 1
fi

# 스크립트 위치 기준 설정
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# config.sh 환경변수 파일 로드
if [ -f "${SCRIPT_DIR}/config.sh" ]; then
  source "${SCRIPT_DIR}/config.sh"
fi

# 기본 버전은 config.sh에서 먼저 가져오고, 인자가 주어지면 덮어씁니다.
default_k8s_ver="${KUBERNETES_VERSION:-v1.35}"
K8S_VERSION="${1:-$default_k8s_ver}"

echo "============================================================="
echo "Kubernetes 도구 설치 스크립트 (kubelet, kubeadm, kubectl)"
echo "Target Version Series: ${K8S_VERSION}"
echo "============================================================="

# 1. Kubernetes 도구(kubelet, kubeadm, kubectl) 설치 여부 및 버전 매치 체크
PACKAGES_OK=true
CLEAN_VER="${K8S_VERSION#v}" # v1.35 -> 1.35

for pkg in kubelet kubeadm kubectl; do
  # 1-1) 패키지 설치 여부 체크
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "-> ${pkg} 패키지가 설치되어 있지 않습니다."
    PACKAGES_OK=false
    break
  fi
  
  # 1-2) 버전 일치 여부 체크 (예: 설치된 버전이 1.35으로 시작하는지)
  installed_ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "")
  if [[ ! "$installed_ver" =~ ^$CLEAN_VER ]]; then
    echo "-> ${pkg} 버전이 일치하지 않습니다. (설치된 버전: ${installed_ver}, 대상 버전: ${CLEAN_VER}.x)"
    PACKAGES_OK=false
    break
  fi
done

if [ "$PACKAGES_OK" = "true" ]; then
  echo "-> kubelet, kubeadm, kubectl (${CLEAN_VER}.x 시리즈)이 이미 설치되어 있습니다. APT 설치 단계를 건너뜁니다."
else
  echo "-> Kubernetes 도구를 설치 또는 업데이트합니다 (대상 시리즈: ${K8S_VERSION})..."
  
  # 버전이 다를 경우 업데이트를 진행해야 하므로, 기존 고정(hold) 상태를 임시 해제합니다.
  echo "-> 안전한 업데이트/설치를 위해 기존 패키지 고정(hold)을 임시 해제합니다."
  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true

  # 2. 필수 의존성 설치
  echo "[1/4] 필수 패키지 설치"
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gpg

  # 3. Kubernetes 공식 GPG 키 다운로드 및 저장소 등록
  echo "[2/4] Kubernetes APT GPG 키 및 저장소 등록"
  mkdir -p -m 755 /etc/apt/keyrings

  # 기존 파일이 있다면 삭제하여 덮어쓰기 방지 오류 예방
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  # KUBERNETES_VERSION에서 마이너 버전(예: v1.35) 추출
  K8S_MINOR_VERSION=$(echo "$K8S_VERSION" | cut -d. -f1,2)
  if [[ ! "$K8S_MINOR_VERSION" =~ ^v ]]; then
    K8S_MINOR_VERSION="v${K8S_MINOR_VERSION}"
  fi

  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

  # 4. 패키지 설치 및 업데이트
  echo "[3/4] kubeadm, kubelet, kubectl 패키지 설치/업데이트"
  apt-get update
  if [[ "$CLEAN_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    apt-get install -y kubelet=${CLEAN_VER}-1.1 kubeadm=${CLEAN_VER}-1.1 kubectl=${CLEAN_VER}-1.1
  else
    apt-get install -y kubelet kubeadm kubectl
  fi
fi

# 5. 버전 고정 (자동 업데이트 방지)
echo "[4/4] 설치된 패키지 버전 고정"
apt-mark hold kubelet kubeadm kubectl

echo "============================================================="
echo "Kubernetes 도구 설치가 완료되었습니다!"
echo "설치 버전 정보:"
kubeadm version
kubectl version --client
echo "============================================================="
