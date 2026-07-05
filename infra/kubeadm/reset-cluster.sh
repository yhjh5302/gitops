#!/usr/bin/env bash

# Kubeadm 클러스터 안전 정리 및 찌꺼기 컨테이너 강제 소거 스크립트
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo "============================================================="
echo "         Kubeadm 클러스터 안전 정리 스크립트                 "
echo "============================================================="

# 1단계: kubelet 데몬 선제 정지 (자가치유 및 컨테이너 무한 복구 예방)
echo -e " -> 1단계: kubelet 서비스 정지 중..."
sudo systemctl stop kubelet || true

# 1.5단계: containerd 서비스 재시작 (마운트 락 및 좀비 세션 강제 릴리즈)
echo -e " -> 1.5단계: containerd 서비스 재시작 중..."
sudo systemctl restart containerd || true

# 2단계: containerd 내 k8s.io 잔재 컨테이너 및 샌드박스 강제 소거
echo -e " -> 2단계: containerd k8s.io 잔재 컨테이너 강제 소거 중..."
if command -v ctr &>/dev/null; then
  # -q 옵션을 사용하여 헤더 없이 CONTAINER ID만 바로 추출합니다.
  containers=$(sudo ctr -n k8s.io containers list | awk 'NR>1 {print $1}')
  if [ -n "$containers" ]; then
    echo " -> 찌꺼기 컨테이너들의 태스크 및 객체를 강제 소거합니다..."
    for container in $containers; do
      # 컨테이너에 물려있는 태스크가 존재할 수 있으므로 강제 삭제(-f) 후 컨테이너 본체 삭제
      echo "    * 삭제 대상 컨테이너: $container"
      sudo ctr -n k8s.io tasks delete -f "$container" &>/dev/null || true
      sudo ctr -n k8s.io containers delete "$container" &>/dev/null || true
    done
    echo " -> ✓ 모든 k8s.io 컨테이너 및 태스크 삭제 완료."
  else
    echo " -> 제거할 k8s.io 컨테이너가 없습니다."
  fi

  # k8s.io 샌드박스(sb) 찌꺼기 소거
  echo -e " -> containerd k8s.io 잔재 샌드박스 강제 소거 중..."
  sandboxes=$(sudo ctr -n k8s.io sandboxes list | awk 'NR>1 {print $1}')
  if [ -n "$sandboxes" ]; then
    echo " -> 찌꺼기 샌드박스들을 강제 소거합니다..."
    for sb in $sandboxes; do
      echo "    * 삭제 대상 샌드박스: $sb"
      sudo ctr -n k8s.io sandboxes rm -f "$sb" &>/dev/null || true
    done
    echo " -> ✓ 모든 k8s.io 샌드박스 삭제 완료."
  else
    echo " -> 제거할 k8s.io 샌드박스가 없습니다."
  fi
fi

# 3단계: Kubelet 좀비 마운트 해제 및 디렉토리 선제 삭제 (kubeadm reset의 멈춤 현상 원천 예방)
echo -e " -> 3단계: Kubelet 좀비 마운트 강제 해제 및 디렉토리 삭제 중..."
if [ -d /var/lib/kubelet ]; then
  # kubelet 하위 마운트들을 역순으로 정렬하여 Lazy 마운트 해제 (umount -l)
  cat /proc/mounts | awk '{print $2}' | grep '^/var/lib/kubelet' | sort -r | xargs -r sudo umount -l || true
  sudo rm -rf /var/lib/kubelet
fi

# 4단계: Kubeadm Reset 실행
echo -e " -> 4단계: Kubeadm Reset 실행 중..."
sudo kubeadm reset -f -v6 || true

# 5단계: CNI 설정 및 잔재 디렉토리 삭제
echo -e " -> 5단계: CNI 설정 디렉토리 삭제 (/etc/cni/net.d)..."
sudo rm -rf /etc/cni/net.d

echo -e "${GREEN}클러스터 정리가 완전히 완료되었습니다!${NC}"
echo "============================================================="
