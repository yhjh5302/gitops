#!/usr/bin/env bash

set -uo pipefail

# 스크립트 위치 기준 설정
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "${SCRIPT_DIR}")"
COMMON_DIR="${INFRA_DIR}/common"
BOOTSTRAP_DIR="${INFRA_DIR}/../gitops/bootstrap"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}        Kind 로컬 개발 클러스터 대화형 구축 스크립트        ${NC}"
echo -e "${BLUE}=============================================================${NC}"



confirm_and_run() {
  local step_name="$1"
  shift
  local cmd=("$@")
  
  echo -e "\n${BLUE}[대기] 단계: ${step_name}${NC}"
  read -p "실행하시겠습니까? (y/N): " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Executing: ${cmd[*]}${NC}"
    "${cmd[@]}"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✓ 성공: ${step_name}${NC}"
    else
      echo -e "${RED}✗ 실패: ${step_name}${NC}"
      exit 1
    fi
  else
    echo -e "안내: 단계를 건너뜁니다."
  fi
}

check_dependencies() {
  echo -e "\n${BLUE}[검사] 필수 도구 설치 여부를 확인합니다...${NC}"
  local missing=0

  if ! command -v docker &>/dev/null; then
    echo -e "${RED}✗ docker가 설치되어 있지 않습니다. Docker를 먼저 설치해주세요.${NC}"
    missing=1
  else
    echo -e "${GREEN}✓ docker가 확인되었습니다.${NC}"
  fi

  if ! command -v kind &>/dev/null; then
    echo -e "${RED}✗ kind가 설치되어 있지 않습니다. Go 또는 바이너리를 통해 kind를 먼저 설치해주세요.${NC}"
    missing=1
  else
    echo -e "${GREEN}✓ kind가 확인되었습니다.${NC}"
  fi

  if ! command -v helm &>/dev/null; then
    echo -e "${RED}✗ helm이 설치되어 있지 않습니다. Helm CLI를 먼저 설치해주세요.${NC}"
    missing=1
  else
    echo -e "${GREEN}✓ helm이 확인되었습니다.${NC}"
  fi

  if [ "$missing" -eq 1 ]; then
    echo -e "${RED}필수 도구가 누락되어 스크립트를 종료합니다.${NC}"
    exit 1
  fi
}

main_menu() {
  check_dependencies

  while true; do
    echo -e "\n${BLUE}--- [Kind Local Setup Menu] ---${NC}"
    echo "1) Kind 로컬 클러스터 생성 (기본 CNI 비활성화)"
    echo "2) Cilium CNI 설치 (eBPF enabled)"
    echo "3) 클러스터 상태 확인 (kubectl get nodes)"
    echo "4) 종료"
    read -p "원하는 단계의 번호를 입력하세요: " choice

    case $choice in
      1)
        confirm_and_run "Kind 클러스터 생성" bash "${SCRIPT_DIR}/create-cluster.sh"
        ;;
      2)
        confirm_and_run "Cilium CNI 설치" bash "${COMMON_DIR}/install-cilium.sh"
        ;;
      3)
        echo -e "\n${BLUE}현재 구성된 K8s 노드 및 네임스페이스 상태:${NC}"
        kubectl get nodes -o wide
        echo ""
        kubectl get pods -A
        ;;
      4)
        echo "스크립트를 종료합니다."
        break
        ;;
      *)
        echo -e "${RED}잘못된 번호입니다.${NC}"
        ;;
    esac
  done
}

main_menu
