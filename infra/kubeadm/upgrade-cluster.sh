#!/usr/bin/env bash
# ==============================================================================
# Production-Grade Kubernetes In-Place Graceful Upgrade Script
# Supports both Control-Plane and Worker Node Upgrades with Fail-Fast Safety
# ==============================================================================

set -euo pipefail

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Helper: Print error and exit immediately (Fail-Fast)
# ------------------------------------------------------------------------------
fail() {
  echo -e "\n${RED}❌ [FATAL ERROR] $1${NC}" >&2
  echo -e "${RED}안전 기준을 충족하지 못하여 업그레이드 작업을 즉시 중단합니다.${NC}" >&2
  exit 1
}

# ------------------------------------------------------------------------------
# Helper: Section Header
# ------------------------------------------------------------------------------
step() {
  echo -e "\n${BLUE}=============================================================${NC}"
  echo -e "${BLUE}▶ $1${NC}"
  echo -e "${BLUE}=============================================================${NC}"
}

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}     Kubernetes Enterprise In-Place Upgrade Orchestrator     ${NC}"
echo -e "${BLUE}=============================================================${NC}"

# Root permission check
if [ "$EUID" -ne 0 ]; then
  fail "이 스크립트는 시스템 커널 및 패키지를 다루므로 root 권한(sudo)으로 실행해야 합니다."
fi

# Load config if present
if [ -f "${SCRIPT_DIR}/config.sh" ]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/config.sh"
fi

# ------------------------------------------------------------------------------
# Argument Parsing (Version, Role, Auto-Confirm)
# ------------------------------------------------------------------------------
TARGET_INPUT=""
SPECIFIED_ROLE=""
AUTO_CONFIRM=false

for arg in "$@"; do
  case "$arg" in
    -y|--yes)
      AUTO_CONFIRM=true
      ;;
    --role=control-plane|--role=cp|-r=cp)
      SPECIFIED_ROLE="control-plane"
      ;;
    --role=worker|-r=worker)
      SPECIFIED_ROLE="worker"
      ;;
    v1.*|1.*)
      TARGET_INPUT="$arg"
      ;;
  esac
done

TARGET_INPUT="${TARGET_INPUT:-${KUBERNETES_VERSION:-v1.37.2}}"
TARGET_CLEAN_VER="${TARGET_INPUT#v}"
TARGET_MAJOR=$(echo "$TARGET_CLEAN_VER" | cut -d. -f1)
TARGET_MINOR=$(echo "$TARGET_CLEAN_VER" | cut -d. -f2)
TARGET_PATCH=$(echo "$TARGET_CLEAN_VER" | cut -d. -f3 | cut -d- -f1)
TARGET_MAJOR_MINOR="v${TARGET_MAJOR}.${TARGET_MINOR}"

# ------------------------------------------------------------------------------
# Node Role Detection & Selection
# ------------------------------------------------------------------------------
DETECTED_ROLE="worker"
if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
  DETECTED_ROLE="control-plane"
fi

SELECTED_ROLE="${SPECIFIED_ROLE:-}"
if [ -z "$SELECTED_ROLE" ]; then
  if [ "$AUTO_CONFIRM" = "true" ]; then
    SELECTED_ROLE="$DETECTED_ROLE"
  else
    echo -e "${YELLOW}감지된 노드 환경: ${BOLD}${DETECTED_ROLE}${NC}"
    echo "업그레이드할 노드 역할을 선택해주세요:"
    echo "  1) Control-Plane (Control-Plane 컴포넌트 롤링 업데이트 + Kubelet/Kubectl)"
    echo "  2) Worker Node    (kubeadm upgrade node + Kubelet/Kubectl)"
    
    DEFAULT_CHOICE="1"
    [ "$DETECTED_ROLE" = "worker" ] && DEFAULT_CHOICE="2"
    
    read -r -p "선택 [1/2] (기본값: ${DEFAULT_CHOICE}): " ROLE_INPUT
    ROLE_INPUT="${ROLE_INPUT:-$DEFAULT_CHOICE}"
    
    if [ "$ROLE_INPUT" = "1" ]; then
      SELECTED_ROLE="control-plane"
    elif [ "$ROLE_INPUT" = "2" ]; then
      SELECTED_ROLE="worker"
    else
      fail "잘못된 선택입니다. 1 또는 2를 입력하세요."
    fi
  fi
fi

echo -e "\n-> 선택된 노드 역할: ${BOLD}${GREEN}${SELECTED_ROLE^^}${NC}"
echo -e "-> 목표 업그레이드 버전: ${BOLD}${GREEN}v${TARGET_CLEAN_VER}${NC} (시리즈: ${TARGET_MAJOR_MINOR})"

# ==============================================================================
# COMMON PHASE 1: 사전 필수 도구 및 디스크 검증
# ==============================================================================
step "Phase 1: 사전 필수 도구 및 시스템 가용 공간 검증"

REQUIRED_CMDS=("kubeadm" "curl" "awk" "sed" "tar" "df")
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    fail "필수 CLI 도구 '${cmd}'가 설치되어 있지 않습니다."
  fi
done
echo -e " -> ${GREEN}✓ 기본 CLI 도구 검증 완료${NC}"

AVAIL_DISK_KB=$(df -k /var/lib | awk 'NR==2 {print $4}')
MIN_DISK_KB=$((3 * 1024 * 1024)) # 3GB (Worker 노드 고려)
if [ "$AVAIL_DISK_KB" -lt "$MIN_DISK_KB" ]; then
  fail "/var/lib 디스크 여유 공간이 부족합니다 (현재: $((AVAIL_DISK_KB / 1024))MB, 최소 요구: 3072MB)."
fi
echo -e " -> ${GREEN}✓ /var/lib 여유 디스크 공간 확인 완료${NC} ($((AVAIL_DISK_KB / 1024 / 1024))GB 가용)"

# ==============================================================================
# COMMON PHASE 2: APT 저장소 스위칭 및 패키지 검증
# ==============================================================================
step "Phase 2: APT 저장소 (${TARGET_MAJOR_MINOR}) 스위칭 및 패키지 검증"

echo " -> pkgs.k8s.io 저장소 네트워크 연결 테스트..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://pkgs.k8s.io/core:/stable:/${TARGET_MAJOR_MINOR}/deb/Release")
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "302" ]; then
  fail "pkgs.k8s.io 저장소 접근 실패 (HTTP 응답: ${HTTP_CODE}). 네트워크 또는 방화벽을 확인하세요."
fi

APT_LIST="/etc/apt/sources.list.d/kubernetes.list"
mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${TARGET_MAJOR_MINOR}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${TARGET_MAJOR_MINOR}/deb/ /" > "$APT_LIST"

echo " -> APT 패키지 인덱스 동기화..."
if ! apt-get update >/dev/null; then
  fail "'apt-get update' 실패. 패키지 저장소 설정을 확인하세요."
fi

PKG_VER=$(apt-cache madison kubeadm | awk -v v="$TARGET_CLEAN_VER" '$3 ~ "^" v {print $3; exit}')
if [ -z "$PKG_VER" ]; then
  PKG_VER=$(apt-cache madison kubeadm | awk -v v="${TARGET_MAJOR}.${TARGET_MINOR}" '$3 ~ "^" v {print $3; exit}')
fi

if [ -z "$PKG_VER" ]; then
  fail "APT 저장소에서 v${TARGET_CLEAN_VER}에 해당하는 kubeadm 패키지를 찾을 수 없습니다."
fi
echo -e " -> ${GREEN}✓ 설치 대상 패키지 버전:${NC} ${BOLD}${PKG_VER}${NC}"

# ==============================================================================
# BRANCH: WORKER NODE UPGRADE FLOW
# ==============================================================================
if [ "$SELECTED_ROLE" = "worker" ]; then
  step "Worker Node 업그레이드 프로세스 시작"

  if [ ! -f /etc/kubernetes/kubelet.conf ]; then
    fail "/etc/kubernetes/kubelet.conf 파일이 없습니다. 이 노드는 클러스터에 조인된 노드가 아닙니다."
  fi

  echo " -> 1. Kubeadm 도구 최신화 (${PKG_VER})..."
  apt-mark unhold kubeadm >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages kubeadm="${PKG_VER}" >/dev/null
  apt-mark hold kubeadm >/dev/null 2>&1

  echo " -> 2. 워커 노드 Kubeadm 설정 업그레이드 (kubeadm upgrade node)..."
  if ! kubeadm upgrade node; then
    fail "kubeadm upgrade node 실행 실패."
  fi
  echo -e " -> ${GREEN}✓ kubeadm upgrade node 완료${NC}"

  echo " -> 3. Kubelet 및 Kubectl 패키지 업그레이드 (${PKG_VER})..."
  apt-mark unhold kubelet kubectl >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages kubelet="${PKG_VER}" kubectl="${PKG_VER}" >/dev/null
  apt-mark hold kubelet kubectl >/dev/null 2>&1

  echo " -> 4. systemd 데몬 재로드 및 Kubelet 서비스 재시작..."
  systemctl daemon-reload
  systemctl restart kubelet
  sleep 3

  if ! systemctl is-active --quiet kubelet; then
    fail "Kubelet 서비스가 정상 기동되지 않았습니다. 'systemctl status kubelet'을 확인하세요."
  fi

  echo -e "\n${GREEN}=============================================================${NC}"
  echo -e "${GREEN}🎉 워커 노드 (v${TARGET_CLEAN_VER}) 업그레이드가 성공적으로 완료되었습니다!${NC}"
  echo -e "${GREEN}=============================================================${NC}"
  echo "Control-Plane 노드에서 'kubectl get nodes'를 실행하여 상태를 확인해주세요."
  exit 0
fi

# ==============================================================================
# BRANCH: CONTROL-PLANE UPGRADE FLOW
# ==============================================================================

# Control-Plane 전용 의존성 검증
for cmd in "kubectl" "jq"; do
  if ! command -v "$cmd" &>/dev/null; then
    fail "Control-Plane 필수 도구 '${cmd}'가 설치되어 있지 않습니다."
  fi
done

if [ ! -f /etc/kubernetes/admin.conf ]; then
  fail "/etc/kubernetes/admin.conf 파일이 없습니다. Control-Plane 권한이 필요합니다."
fi
export KUBECONFIG=/etc/kubernetes/admin.conf

step "Control-Plane 건전성 및 버전 점프 검증 (Health & Skew Policy)"

CURRENT_GIT_VER=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
CURRENT_CLEAN_VER="${CURRENT_GIT_VER#v}"
CURRENT_MAJOR=$(echo "$CURRENT_CLEAN_VER" | cut -d. -f1)
CURRENT_MINOR=$(echo "$CURRENT_CLEAN_VER" | cut -d. -f2)
CURRENT_PATCH=$(echo "$CURRENT_CLEAN_VER" | cut -d. -f3 | cut -d- -f1)

echo " -> 현재 Control-Plane 버전: v${CURRENT_MAJOR}.${CURRENT_MINOR}.${CURRENT_PATCH}"
echo " -> 목표 Control-Plane 버전: v${TARGET_MAJOR}.${TARGET_MINOR}.${TARGET_PATCH}"

MINOR_DIFF=$((TARGET_MINOR - CURRENT_MINOR))
if [ "$MINOR_DIFF" -lt 0 ]; then
  fail "Kubeadm은 클러스터 다운그레이드를 지원하지 않습니다."
elif [ "$MINOR_DIFF" -eq 0 ]; then
  if [ "$TARGET_PATCH" -le "$CURRENT_PATCH" ]; then
    echo -e "${YELLOW}이미 대상 버전(v${TARGET_CLEAN_VER})과 같거나 더 높은 버전입니다.${NC}"
    exit 0
  fi
  echo -e " -> ${GREEN}동일 마이너 패치 업그레이드 확인${NC}"
elif [ "$MINOR_DIFF" -eq 1 ]; then
  echo -e " -> ${GREEN}순차 마이너 버전 업그레이드 확인${NC}"
else
  fail "버전 점프 규칙 위반: 한 번에 2개 이상의 마이너 버전을 건너뛸 수 없습니다."
fi

CP_NODE_NAME=$(hostname)
CORE_COMPONENTS=("kube-apiserver" "etcd" "kube-controller-manager" "kube-scheduler")
for comp in "${CORE_COMPONENTS[@]}"; do
  pod_status=$(kubectl get pods -n kube-system -l "component=${comp}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
  if [ "$pod_status" != "Running" ]; then
    fail "핵심 시스템 파드 '${comp}'가 Running 상태가 아닙니다 (현재: ${pod_status})."
  fi
done
echo -e " -> ${GREEN}✓ 핵심 제어 파드 정상 가동 확인 완료${NC}"

ETCD_HEALTH=$(kubectl exec -n kube-system "etcd-${CP_NODE_NAME}" -- \
  etcdctl endpoint health \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key 2>/dev/null || echo "Unhealthy")
if [[ ! "$ETCD_HEALTH" =~ "is healthy" ]]; then
  fail "etcd 헬스체크 실패: ${ETCD_HEALTH}"
fi
echo -e " -> ${GREEN}✓ etcd 헬스체크 완료${NC}"

# Data Backup
step "데이터 안전 백업 (etcd Snapshot & Config Archive)"
BACKUP_DIR="/var/lib/etcd-backup"
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SNAPSHOT_PATH="${BACKUP_DIR}/etcd-snapshot-${TIMESTAMP}.db"

kubectl exec -n kube-system "etcd-${CP_NODE_NAME}" -- \
  etcdctl snapshot save "/var/lib/etcd/upgrade-snapshot.db" \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key >/dev/null

if [ -f "/var/lib/etcd/upgrade-snapshot.db" ]; then
  mv /var/lib/etcd/upgrade-snapshot.db "${SNAPSHOT_PATH}"
fi

if [ ! -s "${SNAPSHOT_PATH}" ]; then
  fail "etcd 스냅샷 백업 실패! 크기가 0바이트입니다."
fi
echo -e " -> ${GREEN}✓ etcd 스냅샷 백업 완료${NC} (${SNAPSHOT_PATH})"

tar -czf "${BACKUP_DIR}/k8s-manifests-pki-${TIMESTAMP}.tar.gz" -C /etc/kubernetes manifests pki admin.conf kubelet.conf >/dev/null 2>&1
echo -e " -> ${GREEN}✓ /etc/kubernetes 아카이브 완료${NC}"

# Pre-pulling images
step "신규 K8s 컴포넌트 이미지 사전 다운로드 (Pre-pull Images)"
apt-mark unhold kubeadm >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages kubeadm="${PKG_VER}" >/dev/null
apt-mark hold kubeadm >/dev/null 2>&1

if ! kubeadm config images pull --kubernetes-version "v${TARGET_CLEAN_VER}"; then
  fail "신규 K8s 컴포넌트 이미지 다운로드 실패!"
fi
echo -e " -> ${GREEN}✓ 신규 K8s 컨테이너 이미지 사전 풀링 완료${NC}"

# Plan & Confirmation
step "Kubeadm Upgrade Plan 및 사용자 확인"
kubeadm upgrade plan "v${TARGET_CLEAN_VER}"

if [ "$AUTO_CONFIRM" = "false" ]; then
  echo -e "\n${YELLOW}${BOLD}⚠️ 주의: Control-Plane 컴포넌트(apiserver, etcd 등)가 순차적으로 재시작됩니다.${NC}"
  read -r -p "정말로 Kubernetes v${TARGET_CLEAN_VER} Control-Plane 업그레이드를 진행하시겠습니까? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}사용자에 의해 업그레이드가 취소되었습니다.${NC}"
    exit 0
  fi
fi

# Execute Upgrade
step "Control-Plane 업그레이드 적용 (kubeadm upgrade apply)"
if ! kubeadm upgrade apply "v${TARGET_CLEAN_VER}" -y; then
  fail "kubeadm upgrade apply 실패. 백업 파일(${SNAPSHOT_PATH})을 확인하세요."
fi
echo -e " -> ${GREEN}✓ Control-Plane 컴포넌트 업그레이드 완료${NC}"

# Local Kubelet Upgrade
step "Control-Plane Kubelet & Kubectl 패키지 갱신 및 서비스 재기동"
apt-mark unhold kubelet kubectl >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages kubelet="${PKG_VER}" kubectl="${PKG_VER}" >/dev/null
apt-mark hold kubelet kubectl >/dev/null 2>&1

systemctl daemon-reload
systemctl restart kubelet

READY=false
for i in {1..30}; do
  STATUS=$(kubectl get node "${CP_NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$STATUS" == "True" ]; then
    READY=true
    break
  fi
  sleep 2
done

if [ "$READY" != "true" ]; then
  fail "Kubelet 재시작 후 노드가 Ready 상태로 복귀하지 못했습니다."
fi
echo -e " -> ${GREEN}✓ Control-Plane 노드 Ready 상태 확인 완료${NC}"

step "최종 클러스터 상태 확인"
kubectl get nodes -o wide

echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}🎉 Control-Plane (v${TARGET_CLEAN_VER}) 업그레이드가 성공적으로 완료되었습니다!${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo
echo -e "${YELLOW}${BOLD}다음 단계: 워커 노드(jin-vm) 업그레이드${NC}"
echo "워커 노드에 접속하여 아래 명령을 실행하시면 'Worker Node'로 자동 감지되어 원클릭으로 업그레이드됩니다:"
echo -e "${BOLD}-------------------------------------------------------------"
echo "sudo ./infra/kubeadm/upgrade-cluster.sh v${TARGET_CLEAN_VER} --role=worker"
echo -e "-------------------------------------------------------------${NC}"
echo
