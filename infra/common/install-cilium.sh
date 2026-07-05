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

# 2. Cilium Helm 설치 파라미터 변수 정의 (인자 또는 환경변수로부터 획득)
K8S_SERVICE_HOST="${K8S_SERVICE_HOST:-local-cluster-control-plane}"
K8S_SERVICE_PORT="${K8S_SERVICE_PORT:-6443}"
POD_CIDR="${POD_CIDR:-10.233.0.0/16}"

# 위치 파라미터가 선언되었을 경우 덮어쓰기 지원
if [ $# -ge 1 ] && [ -n "$1" ]; then
  K8S_SERVICE_HOST="$1"
fi
if [ $# -ge 2 ] && [ -n "$2" ]; then
  K8S_SERVICE_PORT="$2"
fi
if [ $# -ge 3 ] && [ -n "$3" ]; then
  POD_CIDR="$3"
fi

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
  echo " -> 멀티 노드 클러스터 감지: 기본 이중화 모드로 대기 설치를 진행합니다."
  HELM_EXTRA_ARGS+=("--wait" "--timeout" "5m")
else
  echo " -> ⚠️ 경고: 활성화된 노드를 감지할 수 없습니다. 대기 없이 배포를 진행합니다."
fi

echo "4단계: Cilium CNI 설치 (Kube-Proxy 대체 모드 및 eBPF 호스트 라우팅)"
helm upgrade --install cilium cilium/cilium \
  --version 1.19.5 \
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
