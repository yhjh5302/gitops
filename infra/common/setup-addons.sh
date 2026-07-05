#!/usr/bin/env bash

# Kubernetes 필수 애드온(CNI, Vault, ESO, Cert Manager) 통합 설치 스크립트
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}        Kubernetes Core Addons 통합 설치 (setup-addons.sh)   ${NC}"
echo -e "${BLUE}=============================================================${NC}"

# 1. 필수 도구 및 쿠버네티스 클러스터 연결 가능 여부 확인
if ! command -v jq &>/dev/null; then
  echo -e "${RED}오류: 이 스크립트를 기동하려면 'jq' 도구가 필요합니다. 먼저 설치해주세요.${NC}" >&2
  echo -e "${RED}설치 예시: sudo apt-get update && sudo apt-get install -y jq${NC}" >&2
  exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}오류: 현재 연결 가능한 쿠버네티스 클러스터가 없거나 접근 권한이 없습니다.${NC}" >&2
  echo -e "${RED}kubeconfig(kubectl config get-contexts) 설정을 다시 확인해주세요.${NC}" >&2
  exit 1
fi
echo " -> ✓ 쿠버네티스 클러스터 연결 확인 완료."

# 2. 애드온 검증 및 설치 공통 함수 정의
check_and_install_addon() {
  local release_name="$1"
  local namespace="$2"
  local install_script="$3"
  shift 3
  local script_args=("$@")

  echo -e "\n${BLUE}▶ ${release_name} 상태 확인 중... (네임스페이스: ${namespace})${NC}"
  
  local status_json
  if status_json=$(helm status "${release_name}" -n "${namespace}" -o json 2>/dev/null); then
    local status
    status=$(echo "${status_json}" | jq -r '.info.status' 2>/dev/null || echo "")

    if [ "${status}" = "deployed" ]; then
      echo -e "${GREEN} -> ✓ ${release_name}은(는) 이미 정상 배포('deployed') 상태입니다. 설치를 스킵합니다.${NC}"
      return 0
    else
      echo -e "${RED} -> ⚠️ 경고: ${release_name}의 상태가 비정상('${status}')입니다. 기존 배포를 삭제하고 재설치합니다.${NC}"
      helm uninstall "${release_name}" -n "${namespace}" --wait || true
    fi
  else
    echo " -> ${release_name}이(가) 설치되어 있지 않습니다. 신규 설치를 진행합니다."
  fi

  bash "${install_script}" "${script_args[@]}"
}

# 3. 클러스터 환경 정보 자동 감지 (Host, Port, Pod CIDR)
SERVER_ADDR=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | sed 's|https://||')
AUTO_HOST="${SERVER_ADDR%:*}"
AUTO_PORT="${SERVER_ADDR##*:}"

# kube-proxy ConfigMap에서 클러스터 전체 Pod CIDR을 먼저 조회합니다.
AUTO_CIDR=$(kubectl get cm -n kube-system kube-proxy -o yaml 2>/dev/null | awk '/podCIDR/ {print $2}' | tr -d '"')

# 못 찾았을 경우에만 노드의 podCIDR을 감지하여 /16 대역으로 보정하여 사용합니다.
if [ -z "${AUTO_CIDR}" ]; then
  NODE_CIDR=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null)
  if [ -n "${NODE_CIDR}" ]; then
    # 10.233.0.0/24 -> 10.233.0.0/16 형식으로 보정
    AUTO_CIDR=$(echo "${NODE_CIDR}" | sed -E 's|([0-9]+\.[0-9]+)\.[0-9]+\.[0-9]+/[0-9]+|\1.0.0/16|')
  fi
fi

# 파라미터 매핑 (인자 우선 -> 자동 감지 -> 기본값 순)
K8S_SERVICE_HOST="${1:-${AUTO_HOST:-local-cluster-control-plane}}"
K8S_SERVICE_PORT="${3:-${AUTO_PORT:-6443}}"
POD_CIDR="${2:-${AUTO_CIDR:-10.233.0.0/16}}"

echo -e " -> 감지 및 설정된 인프라 배포 매개변수:"
echo -e "    * API Server Host : ${K8S_SERVICE_HOST}"
echo -e "    * API Server Port : ${K8S_SERVICE_PORT}"
echo -e "    * Pod CIDR Block  : ${POD_CIDR}"
echo -e "-------------------------------------------------------------"

# 4. 각 애드온 검증 및 설치 실행
check_and_install_addon "cilium" "kube-system" "${SCRIPT_DIR}/install-cilium.sh" "${K8S_SERVICE_HOST}" "${K8S_SERVICE_PORT}" "${POD_CIDR}"

echo -e "\n${BLUE}▶ local-path-provisioner 상태 확인 중... (네임스페이스: local-path-storage)${NC}"
if kubectl get storageclass local-path &>/dev/null; then
  echo -e "${GREEN} -> ✓ local-path-provisioner은(는) 이미 정상 설치되어 있습니다. 설치를 스킵합니다.${NC}"
else
  echo " -> local-path-provisioner이(가) 설치되어 있지 않습니다. 신규 설치를 진행합니다."
  bash "${SCRIPT_DIR}/install-local-path.sh"
fi

check_and_install_addon "cert-manager" "cert-manager" "${SCRIPT_DIR}/install-cert-manager.sh"

check_and_install_addon "vault" "vault" "${SCRIPT_DIR}/install-vault.sh"

check_and_install_addon "external-secrets" "external-secrets" "${SCRIPT_DIR}/install-external-secrets.sh"

echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}✓ 모든 Core Addons 설치 및 검증 작업을 성공적으로 완료했습니다!${NC}"
echo -e "${GREEN}=============================================================${NC}"
