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
default_nv_ver="${NVIDIA_DRIVER_VERSION:-580}"
NVIDIA_VERSION="${1:-$default_nv_ver}"

echo "============================================================="
echo "NVIDIA GPU Driver 설치 스크립트 (LTS Open Kernel 모듈)"
echo "Target Driver Major Version: nvidia-driver-${NVIDIA_VERSION}-open"
echo "============================================================="

# 1. NVIDIA GPU 드라이버 설치
echo "[1/1] NVIDIA 드라이버 설치 검사"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  echo "-> nvidia-smi가 이미 정상 작동 중입니다. 드라이버 설치를 건너뜁니다."
  nvidia-smi
elif dpkg -l | grep -q "nvidia-driver-${NVIDIA_VERSION}-open"; then
  echo "-> 이미 nvidia-driver-${NVIDIA_VERSION}-open 패키지가 설치되어 있습니다."
else
  echo "-> nvidia-driver-${NVIDIA_VERSION}-open 설치를 진행합니다 (마이너는 자동 최신 적용)."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "nvidia-driver-${NVIDIA_VERSION}-open"
  echo "-> 드라이버 설치가 완료되었습니다."
  echo "⚠️ 중요: 드라이버 활성화를 위해 시스템 재부팅(sudo reboot)이 꼭 필요합니다."
fi

echo "============================================================="
echo "NVIDIA GPU 드라이버 구성 프로세스가 완료되었습니다!"
echo "재부팅 후 'nvidia-smi' 명령어가 동작하는지 확인하세요."
echo "============================================================="
