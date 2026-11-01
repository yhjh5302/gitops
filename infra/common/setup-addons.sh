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

# 1-1. 과도기 CSR 자동 승인 (부트스트랩 전 노드 통신 보장)
echo " -> [보조] 펜딩 상태인 kubelet CSR 자동 승인 중..."
kubectl get csr 2>/dev/null | grep Pending | awk '{print $1}' | xargs -r kubectl certificate approve >/dev/null 2>&1 || true

# 2. 애드온 검증 및 설치 공통 함수 정의
check_and_install_addon() {
  local release_name="$1"
  local namespace="$2"
  local install_script="$3"
  shift 3
  local script_args=("$@")

  echo -e "\n${BLUE}▶ ${release_name} 상태 확인 중... (네임스페이스: ${namespace})${NC}"

  local target_version
  target_version=$(grep -E -- '--version[ =]' "${install_script}" 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d '"' | tr -d "'" || echo "")

  local release_info
  release_info=$(helm list -n "${namespace}" -f "^${release_name}$" -o json 2>/dev/null | jq -r '.[0] // empty')

  if [ -n "${release_info}" ]; then
    local status deployed_chart
    status=$(echo "${release_info}" | jq -r '.status // empty')
    deployed_chart=$(echo "${release_info}" | jq -r '.chart // empty')

    # Vault 특수 케이스: OnDelete 전략으로 인해 파드가 이전 이미지로 남아있는지 확인
    local pod_needs_update=false
    local v_cur="" v_target=""
    if [ "${release_name}" = "vault" ]; then
      v_cur=$(kubectl get pod vault-0 -n vault -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || echo "")
      v_target=$(kubectl get statefulset vault -n vault -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
      if [ -n "${v_cur}" ] && [ -n "${v_target}" ] && [ "${v_cur}" != "${v_target}" ]; then
        pod_needs_update=true
      fi
    fi

    if [ "${status}" = "deployed" ] && [ "${pod_needs_update}" = "false" ]; then
      if [ -n "${target_version}" ] && [[ "${deployed_chart}" != *"-${target_version}" ]]; then
        echo -e "${BLUE} -> 🔄 버전 업데이트 감지: 현재(${deployed_chart}) != 목표(${target_version}). 업그레이드를 진행합니다.${NC}"
      else
        echo -e "${GREEN} -> ✓ ${release_name}은(는) 이미 목표 버전(${deployed_chart})으로 정상 배포('deployed') 상태입니다. 설치를 스킵합니다.${NC}"
        return 0
      fi
    elif [ "${pod_needs_update}" = "true" ]; then
      echo -e "${BLUE} -> 🔄 Vault 파드 이미지 업데이트 감지: 현재(${v_cur}) != 목표(${v_target}). 파드 갱신 및 Unseal을 진행합니다.${NC}"
    else
      echo -e "${RED} -> ⚠️ 경고: ${release_name}의 배포 상태가 비정상('${status}')입니다. 복구 배포를 진행합니다.${NC}"
    fi
  else
    echo " -> ${release_name}이(가) 설치되어 있지 않습니다. 신규 설치를 진행합니다."
  fi

  bash "${install_script}" "${script_args[@]}"
}

# 3. 클러스터 환경 정보 자동 감지 (Host, Port, Pod CIDR, Kind vs Kubeadm)
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
SERVER_ADDR=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | sed -E 's|https?://||')
AUTO_HOST="${SERVER_ADDR%:*}"
AUTO_PORT="${SERVER_ADDR##*:}"

# kube-proxy ConfigMap 또는 kubeadm-config 또는 Node podCIDR 순으로 조회
AUTO_CIDR=$(kubectl get cm -n kube-system kube-proxy -o yaml 2>/dev/null | awk '/podCIDR/ {print $2}' | tr -d '"')
if [ -z "${AUTO_CIDR}" ]; then
  AUTO_CIDR=$(kubectl get cm -n kube-system kubeadm-config -o yaml 2>/dev/null | awk '/podSubnet:/ {print $2}' | tr -d '"')
fi
if [ -z "${AUTO_CIDR}" ]; then
  NODE_CIDR=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null)
  if [ -n "${NODE_CIDR}" ]; then
    AUTO_CIDR=$(echo "${NODE_CIDR}" | sed -E 's|([0-9]+\.[0-9]+)\.[0-9]+\.[0-9]+/[0-9]+|\1.0.0/16|')
  fi
fi

# Kind 환경인지 확인 (Context 접두사 kind- 또는 로컬 loopback 주소 감지)
if [[ "${CURRENT_CTX}" == kind-* ]] || [[ "${AUTO_HOST}" == "127.0.0.1" ]] || [[ "${AUTO_HOST}" == "localhost" ]]; then
  KIND_CP_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "local-cluster-control-plane")
  DEFAULT_HOST="${KIND_CP_NODE:-local-cluster-control-plane}"
  DEFAULT_PORT="6443"
  DEFAULT_CIDR="${AUTO_CIDR:-10.233.0.0/16}"
  echo " -> 클러스터 환경 감지: Kind 환경 (${CURRENT_CTX}, Control-Plane Node: ${DEFAULT_HOST})"
else
  DEFAULT_HOST="${AUTO_HOST:-cluster-endpoint}"
  DEFAULT_PORT="${AUTO_PORT:-6443}"
  DEFAULT_CIDR="${AUTO_CIDR:-10.233.0.0/16}"
  echo " -> 클러스터 환경 감지: Kubeadm/외부 환경 (${CURRENT_CTX}, API Endpoint: ${DEFAULT_HOST}:${DEFAULT_PORT})"
fi

# 위치 인자 처리 ($1: HOST, $2: PORT 또는 CIDR, $3: CIDR 또는 PORT)
if [ $# -ge 2 ] && [[ "$2" == *"/"* ]]; then
  K8S_SERVICE_HOST="${1:-${K8S_SERVICE_HOST:-${DEFAULT_HOST}}}"
  POD_CIDR="${2:-${POD_CIDR:-${DEFAULT_CIDR}}}"
  K8S_SERVICE_PORT="${3:-${K8S_SERVICE_PORT:-${DEFAULT_PORT}}}"
else
  K8S_SERVICE_HOST="${1:-${K8S_SERVICE_HOST:-${DEFAULT_HOST}}}"
  K8S_SERVICE_PORT="${2:-${K8S_SERVICE_PORT:-${DEFAULT_PORT}}}"
  POD_CIDR="${3:-${POD_CIDR:-${DEFAULT_CIDR}}}"
fi

echo -e " -> 감지 및 설정된 인프라 배포 매개변수:"
echo -e "    * API Server Host : ${K8S_SERVICE_HOST}"
echo -e "    * API Server Port : ${K8S_SERVICE_PORT}"
echo -e "    * Pod CIDR Block  : ${POD_CIDR}"
echo -e "-------------------------------------------------------------"

# 4. 각 애드온 검증 및 설치 실행
check_and_install_addon "cilium" "kube-system" "${SCRIPT_DIR}/install-cilium.sh" "${K8S_SERVICE_HOST}" "${K8S_SERVICE_PORT}" "${POD_CIDR}"

echo -e "\n${BLUE}▶ local-path-provisioner 상태 확인 중... (네임스페이스: local-path-storage)${NC}"
LOCAL_PATH_TARGET_VERSION=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "${SCRIPT_DIR}/install-local-path.sh" | head -n 1 || echo "v0.0.36")
CURRENT_IMAGE=$(kubectl get deployment -n local-path-storage local-path-provisioner -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if [ -n "${CURRENT_IMAGE}" ] && kubectl get storageclass local-path &>/dev/null; then
  if [[ "${CURRENT_IMAGE}" == *":${LOCAL_PATH_TARGET_VERSION}"* ]]; then
    echo -e "${GREEN} -> ✓ local-path-provisioner은(는) 이미 목표 버전(${LOCAL_PATH_TARGET_VERSION})으로 정상 설치되어 있습니다. 설치를 스킵합니다.${NC}"
  else
    echo -e "${BLUE} -> 🔄 local-path-provisioner 버전 업데이트 감지: 현재(${CURRENT_IMAGE}) != 목표(${LOCAL_PATH_TARGET_VERSION}). 재배포합니다.${NC}"
    bash "${SCRIPT_DIR}/install-local-path.sh"
  fi
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
