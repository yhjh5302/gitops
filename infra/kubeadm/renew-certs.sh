#!/usr/bin/env bash

set -euo pipefail

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}        Kubernetes 제어 평면 및 Kubelet 인증서 갱신 스크립트        ${NC}"
echo -e "${BLUE}=============================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}오류: 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.${NC}" >&2
  exit 1
fi

echo -e "${GREEN}1단계: Control Plane 인증서 상태 확인${NC}"
kubeadm certs check-expiration

echo -e "\n${GREEN}2단계: Control Plane 인증서 갱신 (kubeadm certs renew all)${NC}"
kubeadm certs renew all

echo -e "\n${GREEN}3단계: admin.conf 및 일반 사용자 Kubeconfig 갱신${NC}"
# admin.conf 갱신은 자동으로 되나 일반 사용자 디렉토리로 복사 필요
TARGET_USER="${SUDO_USER:-}"
if [ -n "$TARGET_USER" ]; then
  TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  if [ -d "${TARGET_HOME}/.kube" ]; then
    echo " -> ${TARGET_HOME}/.kube/config에 최신 admin.conf 복사 및 소유권 변경"
    cp -f /etc/kubernetes/admin.conf "${TARGET_HOME}/.kube/config"
    TARGET_UID=$(getent passwd "$TARGET_USER" | cut -d: -f3)
    TARGET_GID=$(getent passwd "$TARGET_USER" | cut -d: -f4)
    chown "${TARGET_UID}:${TARGET_GID}" "${TARGET_HOME}/.kube/config"
  fi
fi

# root 사용자의 kubeconfig 갱신
if [ -d "/root/.kube" ]; then
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
fi

echo -e "\n${GREEN}4단계: 제어 평면 컴포넌트 재시작 (새 인증서 로드)${NC}"
if command -v crictl &>/dev/null; then
  echo " -> crictl을 사용하여 API server, Controller Manager, Scheduler, etcd 컨테이너 재시작"
  # static pod들의 sandbox ID 검색하여 삭제 (삭제 시 kubelet이 알아서 다시 띄움)
  crictl pods --namespace kube-system --name 'kube-apiserver-*|kube-controller-manager-*|kube-scheduler-*|etcd-*' -q | xargs -r crictl rmp -f || true
else
  echo " -> crictl 명령어를 찾을 수 없습니다. kubelet 서비스를 재시작합니다."
  systemctl restart kubelet
fi

echo -e "\n${GREEN}5단계: 대기 중인 Kubelet CSR 자동 승인${NC}"
export KUBECONFIG=/etc/kubernetes/admin.conf

echo " -> 5초 대기 후 CSR 확인..."
sleep 5
if command -v kubectl &>/dev/null; then
  PENDING_CSRS=""
  if command -v jq &>/dev/null; then
    PENDING_CSRS=$(kubectl get csr -o json 2>/dev/null | jq -r '.items[] | select(.status.conditions == null) | .metadata.name' 2>/dev/null || true)
  else
    PENDING_CSRS=$(kubectl get csr 2>/dev/null | grep -i 'Pending' | awk '{print $1}' || true)
  fi

  if [ -n "$PENDING_CSRS" ]; then
    echo " -> 다음 CSR 승인 진행: $PENDING_CSRS"
    echo "$PENDING_CSRS" | xargs -r kubectl certificate approve || true
  else
    echo " -> 승인할 대기 상태(Pending)의 CSR이 없습니다."
  fi
else
  echo " -> kubectl 명령어를 찾을 수 없어 CSR 승인 단계를 건너뜁니다."
fi

echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}인증서 갱신 프로세스가 완료되었습니다!${NC}"
echo -e "${GREEN}=============================================================${NC}"
