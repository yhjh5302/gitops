#!/usr/bin/env bash

set -euo pipefail

# 스크립트 디렉토리 파악
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================="
echo "eBPF 기반 Cilium CNI 최적화 설치 스크립트"
echo "============================================================="

# Helm CLI 존재 여부 확인
if ! command -v helm &>/dev/null; then
  echo "오류: helm 명령어가 존재하지 않습니다. Helm을 먼저 설치해주세요." >&2
  exit 1
fi

# 1. Helm 레포지토리 등록 및 업데이트
echo "1단계: Cilium Helm Repository 등록"
helm repo add cilium https://helm.cilium.io/ || true
helm repo update

# 2. 클러스터 환경 정보 자동 감지 (Kind vs Kubeadm/외부 환경)
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
SERVER_ADDR=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | sed -E 's|https?://||')
AUTO_HOST="${SERVER_ADDR%:*}"
AUTO_PORT="${SERVER_ADDR##*:}"

# Pod CIDR 자동 감지 (kube-proxy ConfigMap -> kubeadm-config -> Node podCIDR 순)
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
  echo " -> 클러스터 환경 감지: Kind 환경 (Control-Plane Node: ${DEFAULT_HOST})"
else
  DEFAULT_HOST="${AUTO_HOST:-cluster-endpoint}"
  DEFAULT_PORT="${AUTO_PORT:-6443}"
  DEFAULT_CIDR="${AUTO_CIDR:-10.233.0.0/16}"
  echo " -> 클러스터 환경 감지: Kubeadm/외부 환경 (API Endpoint: ${DEFAULT_HOST}:${DEFAULT_PORT})"
fi

# 최종 파라미터 매핑: 위치 인자($1, $2, $3) -> 환경변수 -> 감지된 기본값 순
K8S_SERVICE_HOST="${1:-${K8S_SERVICE_HOST:-${DEFAULT_HOST}}}"
K8S_SERVICE_PORT="${2:-${K8S_SERVICE_PORT:-${DEFAULT_PORT}}}"
POD_CIDR="${3:-${POD_CIDR:-${DEFAULT_CIDR}}}"

echo " -> Target K8s Service Host: ${K8S_SERVICE_HOST}"
echo " -> Target K8s Service Port: ${K8S_SERVICE_PORT}"
echo " -> Target Pod Network CIDR: ${POD_CIDR}"

# 3. 노드 개수 기반 대기 및 레플리카 분기 처리
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
HELM_EXTRA_ARGS=()

if [ "${NODE_COUNT}" -eq 1 ]; then
  echo " -> 싱글 노드 클러스터 감지: Operator 복제본을 1개로 조정하여 대기를 수행합니다."
  HELM_EXTRA_ARGS+=("--set" "operator.replicas=1" "--wait" "--timeout" "5m")
elif [ "${NODE_COUNT}" -gt 1 ]; then
  echo " -> 멀티 노드 클러스터 감지: 이중화 모드로 배포하며 워커 노드(GPU 등) 테인트를 허용합니다."
  HELM_EXTRA_ARGS+=("--set" "operator.tolerations[0].operator=Exists" "--wait" "--timeout" "5m")
else
  echo " -> ⚠️ 경고: 활성화된 노드를 감지할 수 없습니다. 대기 없이 배포를 진행합니다."
fi

echo "4단계: Cilium CNI 설치 (Kube-Proxy 대체 모드 및 eBPF 호스트 라우팅)"
helm upgrade --install cilium cilium/cilium \
  --version 1.20.4 \
  --namespace kube-system \
  --set k8sServiceHost="${K8S_SERVICE_HOST}" \
  --set k8sServicePort="${K8S_SERVICE_PORT}" \
  --set kubeProxyReplacement=true \
  --set ipam.mode="cluster-pool" \
  --set ipam.operator.clusterPoolIPv4PodCIDRList={"${POD_CIDR}"} \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set endpointRoutes.enabled=true \
  --set ipv6.enabled=false \
  --set bpf.masquerade=true \
  --set routingMode=native \
  --set autoDirectNodeRoutes=true \
  --set installNoConntrackIptablesRules=true \
  --set ipv4NativeRoutingCIDR="${POD_CIDR}" \
  --set loadBalancer.serviceTopology=true \
  --set envoy.enabled=false \
  --set cni.exclusive=false \
  "${HELM_EXTRA_ARGS[@]}"

echo "============================================================="
echo "Cilium CNI 배포가 완료되었습니다!"
echo "============================================================="
