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

DOCKER_DATA_ROOT="${1:-/var/lib/docker}"
DOCKER_EXEC_ROOT="${2:-/var/run/docker}"
CONTAINERD_ROOT="${3:-/var/lib/containerd}"
CONTAINERD_STATE="${4:-/run/containerd}"

echo "============================================================="
echo "Container Runtime (Docker/Containerd) 설치 및 최적화 설정 스크립트"
echo "Target Docker data-root: ${DOCKER_DATA_ROOT}"
echo "Target Docker exec-root: ${DOCKER_EXEC_ROOT}"
echo "Target Containerd root: ${CONTAINERD_ROOT}"
echo "Target Containerd state: ${CONTAINERD_STATE}"
echo "============================================================="

# 1. 기존 충돌 가능한 오래된 리스트 파일 및 GPG 키 제거하여 Signed-By 충돌 방지
if [ -f /etc/apt/sources.list.d/docker.list ]; then
  echo "-> 오래된 /etc/apt/sources.list.d/docker.list 파일을 제거합니다."
  rm -f /etc/apt/sources.list.d/docker.list
fi
if [ -f /etc/apt/keyrings/docker.gpg ]; then
  echo "-> 오래된 /etc/apt/keyrings/docker.gpg 키를 제거합니다."
  rm -f /etc/apt/keyrings/docker.gpg
fi

# 2. Docker 및 Containerd 설치 여부 체크
PACKAGES_INSTALLED=true
for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    PACKAGES_INSTALLED=false
    break
  fi
done

if [ "$PACKAGES_INSTALLED" = "true" ]; then
  echo "-> docker-ce, containerd.io 등의 패키지가 이미 설치되어 있습니다. APT 설치 단계를 건너뜁니다."
else
  # 3. 필수 패키지 설치 및 GPG 키 등록 준비
  echo "[1/4] 필수 유틸리티 및 GPG 키 등록 준비"
  apt-get update -y
  apt-get install -y ca-certificates curl

  echo "[2/4] Docker APT Repository 등록 및 패키지 설치"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # 데비안 레포지토리 소스 파일 추가
  cat <<EOF > /etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# 3. Docker Daemon 데이터 및 런타임 루트 설정, cgroup 드라이버 최적화
echo "[3/4] Docker data-root/exec-root 및 cgroupfs 설정 (/etc/docker/daemon.json)"
mkdir -p /etc/docker

NEED_DOCKER_RESTART=false
DAEMON_JSON="/etc/docker/daemon.json"
WROTE_NEW_DAEMON=false

# daemon.json 이 이미 있고, 내용물 중 data-root와 exec-root가 동일한지 판별
if [ -f "$DAEMON_JSON" ]; then
  if grep -q "\"data-root\": \"${DOCKER_DATA_ROOT}\"" "$DAEMON_JSON" && grep -q "\"exec-root\": \"${DOCKER_EXEC_ROOT}\"" "$DAEMON_JSON"; then
    echo "-> Docker daemon.json이 이미 설정에 부합합니다. 수정을 건너뜁니다."
  else
    cp "$DAEMON_JSON" "${DAEMON_JSON}.bak"
    echo "-> 기존 daemon.json 파일을 daemon.json.bak 로 백업했습니다."
    WROTE_NEW_DAEMON=true
  fi
else
  WROTE_NEW_DAEMON=true
fi

if [ "$WROTE_NEW_DAEMON" = "true" ]; then
  cat <<EOF > "$DAEMON_JSON"
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "exec-root": "${DOCKER_EXEC_ROOT}",
  "insecure-registries": []
}
EOF
  NEED_DOCKER_RESTART=true
fi

# 4. Containerd 설정 및 SystemdCgroup 활성화, root/state 경로 변경
echo "[4/4] Containerd 최적화 구성 (/etc/containerd/config.toml)"
mkdir -p /etc/containerd

CONFIG_FILE="/etc/containerd/config.toml"
NEED_CONTAINERD_RESTART=false

# 4-1. 설정 파일이 없는 경우 기본 설정 생성, 기존 파일이 있다면 CRI 활성화 체크
if [ ! -f "$CONFIG_FILE" ]; then
  echo "-> 기본 config.toml 파일을 생성합니다."
  containerd config default | tee "$CONFIG_FILE" > /dev/null
  NEED_CONTAINERD_RESTART=true
else
  echo "-> 기존 config.toml 파일이 존재하므로 설정을 업데이트합니다."
  # Docker 패키지로 설치될 경우 기본적으로 cri 플러그인이 비활성화 되어 있으므로 강제 활성화합니다.
  if grep -q 'disabled_plugins = \["cri"\]' "$CONFIG_FILE"; then
    sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/g' "$CONFIG_FILE"
    echo "-> disabled_plugins에서 cri 플러그인을 제거하여 CRI를 활성화했습니다."
    NEED_CONTAINERD_RESTART=true
  fi
fi

# 4-2. SystemdCgroup = true 로 설정 (기존 설정 확인 및 치환)
if grep -q "SystemdCgroup = false" "$CONFIG_FILE"; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$CONFIG_FILE"
  echo "-> SystemdCgroup 설정을 true로 활성화했습니다."
  NEED_CONTAINERD_RESTART=true
else
  echo "-> 이미 SystemdCgroup이 true로 설정되어 있거나 설정 항목이 존재하지 않습니다."
fi

# 4-3. Containerd root 경로 수정
current_root=$(grep '^root = ' "$CONFIG_FILE" | cut -d'"' -f2 || echo "")
if [ "$current_root" != "$CONTAINERD_ROOT" ]; then
  if [ -n "$current_root" ]; then
    sed -i "s|root = \"${current_root}\"|root = \"${CONTAINERD_ROOT}\"|g" "$CONFIG_FILE"
  else
    sed -i "1s|^|root = \"${CONTAINERD_ROOT}\"\n|" "$CONFIG_FILE"
  fi
  echo "-> Containerd root 경로를 ${CONTAINERD_ROOT} 로 업데이트했습니다."
  NEED_CONTAINERD_RESTART=true
else
  echo "-> 이미 Containerd root 경로가 ${CONTAINERD_ROOT} 로 설정되어 있습니다."
fi

# 4-4. Containerd state 경로 수정
current_state=$(grep '^state = ' "$CONFIG_FILE" | cut -d'"' -f2 || echo "")
if [ "$current_state" != "$CONTAINERD_STATE" ]; then
  if [ -n "$current_state" ]; then
    sed -i "s|state = \"${current_state}\"|state = \"${CONTAINERD_STATE}\"|g" "$CONFIG_FILE"
  else
    sed -i "1s|^|state = \"${CONTAINERD_STATE}\"\n|" "$CONFIG_FILE"
  fi
  echo "-> Containerd state 경로를 ${CONTAINERD_STATE} 로 업데이트했습니다."
  NEED_CONTAINERD_RESTART=true
else
  echo "-> 이미 Containerd state 경로가 ${CONTAINERD_STATE} 로 설정되어 있습니다."
fi

# 4-5. 샌드박스(pause) 이미지 주소 및 버전 업데이트 (CRI v1/v2 및 config.toml v3 구조 대응)
sandbox_img="${SANDBOX_IMAGE:-registry.k8s.io/pause:3.10.2}"

# 1) 구형 스키마 (sandbox_image)
if grep -q "sandbox_image =" "$CONFIG_FILE"; then
  if ! grep -q "sandbox_image = \"${sandbox_img}\"" "$CONFIG_FILE"; then
    sed -i "s|sandbox_image = \"[^\"]*\"|sandbox_image = \"${sandbox_img}\"|g" "$CONFIG_FILE"
    echo "-> [Legacy] sandbox_image 설정을 ${sandbox_img} 로 업데이트했습니다."
    NEED_CONTAINERD_RESTART=true
  fi
fi

# 2) 최신 containerd v2.0+ 스키마 (pinned_images.sandbox)
if grep -q "sandbox =" "$CONFIG_FILE" || grep -q '\[plugins."io.containerd.cri.v1.images".pinned_images\]' "$CONFIG_FILE"; then
  if ! grep -q "sandbox = \"${sandbox_img}\"" "$CONFIG_FILE"; then
    sed -i "s|sandbox = \"[^\"]*\"|sandbox = \"${sandbox_img}\"|g" "$CONFIG_FILE"
    echo "-> [Modern] pinned_images.sandbox 설정을 ${sandbox_img} 로 업데이트했습니다."
    NEED_CONTAINERD_RESTART=true
  fi
fi

# 4-6. CRI Registry Config Path 설정 (/etc/containerd/certs.d)
if grep -q "config_path = \"\"" "$CONFIG_FILE"; then
  sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' "$CONFIG_FILE"
  echo "-> config_path 설정을 /etc/containerd/certs.d 로 활성화했습니다."
  NEED_CONTAINERD_RESTART=true
elif ! grep -q "config_path = \"/etc/containerd/certs.d\"" "$CONFIG_FILE"; then
  if grep -q '\[plugins."io.containerd.grpc.v1.cri".registry\]' "$CONFIG_FILE"; then
    sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a \      config_path = "/etc/containerd/certs.d"' "$CONFIG_FILE"
    echo "-> config_path 설정을 io.containerd.grpc.v1.cri.registry 아래에 주입했습니다."
  elif grep -q '\[plugins."io.containerd.cri.v1.images".registry\]' "$CONFIG_FILE"; then
    sed -i '/\[plugins."io.containerd.cri.v1.images".registry\]/a \      config_path = "/etc/containerd/certs.d"' "$CONFIG_FILE"
    echo "-> config_path 설정을 io.containerd.cri.v1.images.registry 아래에 주입했습니다."
  else
    echo -e "\n[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  config_path = \"/etc/containerd/certs.d\"" >> "$CONFIG_FILE"
    echo "-> config_path 섹션을 파일 끝에 직접 주입했습니다."
  fi
  NEED_CONTAINERD_RESTART=true
else
  echo "-> 이미 config_path 설정이 /etc/containerd/certs.d 로 설정되어 있습니다."
fi

# 5. AI/GPU 워크로드를 위한 systemd 리소스 제한 해제 설정 (MEMLOCK, NOFILE, NPROC)
echo "Containerd systemd 리소스 한도 확장 설정 주입 (LimitMEMLOCK 등)"
OVERRIDE_DIR="/etc/systemd/system/containerd.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
WROTE_OVERRIDE=false

if [ -f "$OVERRIDE_FILE" ]; then
  if grep -q "LimitMEMLOCK=infinity" "$OVERRIDE_FILE"; then
    echo "-> systemd 리소스 제한 해제 파일이 이미 설정에 부합합니다."
  else
    WROTE_OVERRIDE=true
  fi
else
  WROTE_OVERRIDE=true
fi

if [ "$WROTE_OVERRIDE" = "true" ]; then
  mkdir -p "$OVERRIDE_DIR"
  cat <<EOF > "$OVERRIDE_FILE"
[Service]
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
LimitMEMLOCK=infinity
EOF
  echo "-> systemd 리소스 한도 확장 설정을 갱신했습니다."
  NEED_CONTAINERD_RESTART=true
fi

# 서비스 재기동 (실제 변경 사항이 발생한 대상 서비스만 선별 재기동)
if [ "$NEED_CONTAINERD_RESTART" = "true" ] || [ "$NEED_DOCKER_RESTART" = "true" ]; then
  echo "-> 설정 변경 사항이 감지되어 시스템 서비스를 재기동합니다..."
  systemctl daemon-reload
  
  if [ "$NEED_CONTAINERD_RESTART" = "true" ]; then
    echo " -> restart containerd..."
    systemctl restart containerd
    systemctl enable containerd
  fi
  if [ "$NEED_DOCKER_RESTART" = "true" ]; then
    echo " -> restart docker..."
    systemctl restart docker
    systemctl enable docker
  fi
else
  echo "✓ 변경된 설정 정보가 없습니다. (데몬 재기동 생략 - 다운타임 발생하지 않음)"
fi

# 6. nerdctl 설치 (GitHub API를 통한 최신 릴리즈 자동 추적 및 동적 체크섬 검증)
echo "============================================================="
echo "nerdctl 설치를 진행합니다..."
if command -v nerdctl &>/dev/null; then
  echo "-> nerdctl이 이미 설치되어 있습니다. (버전: $(nerdctl --version))"
else
  echo "-> GitHub API로부터 nerdctl 최신 릴리즈 정보를 조회합니다..."
  LATEST_TAG=$(curl -s https://api.github.com/repos/containerd/nerdctl/releases/latest | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || echo "")
  
  if [ -z "$LATEST_TAG" ]; then
    echo "⚠️ GitHub API 호출 실패 또는 한도 초과. 기본 백업 버전(v2.3.3)으로 시도합니다."
    LATEST_TAG="v2.3.3"
  fi
  
  VERSION="${LATEST_TAG#v}"
  echo "-> 최신 버전 감지 완료: ${LATEST_TAG}"

  # CPU 아키텍처 판별
  HOST_ARCH=$(uname -m)
  NERD_ARCH=""

  case "$HOST_ARCH" in
    x86_64)               NERD_ARCH="amd64" ;;
    aarch64|arm64)        NERD_ARCH="arm64" ;;
    armv7l|armhf)         NERD_ARCH="arm-v7" ;;
    ppc64le)              NERD_ARCH="ppc64le" ;;
    riscv64)              NERD_ARCH="riscv64" ;;
    loongarch64|loong64)  NERD_ARCH="loong64" ;;
    *)
      echo "⚠️ 지원하지 않는 CPU 아키텍처($HOST_ARCH)입니다. nerdctl 자동 설치를 건너뜁니다."
      ;;
  esac

  if [ -n "$NERD_ARCH" ]; then
    TARBALL="nerdctl-${VERSION}-linux-${NERD_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/containerd/nerdctl/releases/download/${LATEST_TAG}/${TARBALL}"
    CHECKSUM_URL="https://github.com/containerd/nerdctl/releases/download/${LATEST_TAG}/SHA256SUMS"
    TMP_DIR=$(mktemp -d)
    
    echo "-> ${DOWNLOAD_URL} 에서 다운로드 중..."
    if curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/${TARBALL}"; then
      # 동적 체크섬 파일 다운로드 및 검증
      echo "-> 공식 체크섬 파일 다운로드 중..."
      if curl -fsSL "$CHECKSUM_URL" -o "${TMP_DIR}/SHA256SUMS"; then
        echo "-> 다운로드한 파일의 SHA256 체크섬을 검증합니다..."
        # SHA256SUMS 내 파일 경로 매핑 후 검증
        if (cd "${TMP_DIR}" && grep "${TARBALL}" SHA256SUMS > verify.sums && sha256sum --check --status verify.sums); then
          echo "✓ 체크섬 검증 성공!"
        else
          echo "❌ 오류: 다운로드된 nerdctl 파일 체크섬이 공식 배포 값과 일치하지 않습니다!"
          rm -rf "$TMP_DIR"
          exit 1
        fi
      else
        echo "⚠️ 경고: 체크섬 파일(SHA256SUMS)을 가져오지 못했습니다. 검증 없이 바이너리 설정을 진행합니다."
      fi
      
      echo "-> /usr/local/bin 에 바이너리를 설치합니다."
      tar -C /usr/local/bin -xzf "${TMP_DIR}/${TARBALL}" nerdctl
      chmod +x /usr/local/bin/nerdctl
      echo "✓ nerdctl 설치 완료: $(sudo nerdctl --version)"
    else
      echo "❌ 오류: nerdctl 다운로드에 실패했습니다."
    fi
    rm -rf "$TMP_DIR"
  fi
fi

echo "============================================================="
echo "설치가 완료되었습니다!"
echo "Docker Data-root: $(sudo docker info --format '{{.DockerRootDir}}')"
echo "Containerd 설정 디렉토리: /etc/containerd/certs.d"
echo "============================================================="
