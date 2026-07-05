#!/usr/bin/env bash

set -euo pipefail

# root 권한 체크
if [ "$EUID" -ne 0 ]; then
  echo "오류: 이 스크립트는 root 권한(sudo)으로 실행해야 합니다."
  exit 1
fi

echo "============================================================="
echo "Kubernetes 노드 사전 준비 스크립트 (Swap 비활성화 & 커널 설정)"
echo "============================================================="

# 1. Swap 비활성화
echo "[1/3] 스왑(Swap) 비활성화 설정"
if [ -n "$(swapon --show)" ]; then
  swapoff -a
  echo "-> 활성화된 스왑을 비활성화했습니다."
else
  echo "-> 이미 활성화된 스왑이 없습니다."
fi

# 주석 처리가 안 된 활성 swap 라인이 있으면 주석 처리
if grep -qE '^[^\#].*swap' /etc/fstab; then
  sed -i '/swap/s/^\([^#]\)/#\1/' /etc/fstab
  echo "-> /etc/fstab의 활성 swap 설정을 주석 처리했습니다."
else
  echo "-> 이미 /etc/fstab 내에 활성화된 swap 설정이 없습니다."
fi

# 2. 커널 모듈 로드 설정
echo "[2/3] 필요한 커널 모듈 활성화 (overlay, br_netfilter)"
K8S_CONF="/etc/modules-load.d/k8s.conf"
touch "$K8S_CONF"

for module in overlay br_netfilter; do
  if ! grep -qxF "$module" "$K8S_CONF"; then
    echo "$module" >> "$K8S_CONF"
    echo "-> $K8S_CONF에 $module 모듈 설정을 추가했습니다."
  else
    echo "-> 이미 $K8S_CONF에 $module 설정이 존재합니다."
  fi
  
  if ! lsmod | grep -q "^${module//-/_}"; then
    modprobe "$module"
    echo "-> $module 커널 모듈을 로드했습니다."
  else
    echo "-> 이미 $module 커널 모듈이 로드되어 있습니다."
  fi
done

# 3. sysctl 네트워크 파라미터 설정
echo "[3/3] 네트워크 브릿지 및 IP 포워딩 sysctl 설정"
SYSCTL_CONF="/etc/sysctl.d/k8s.conf"
touch "$SYSCTL_CONF"

declare -A sysctl_params=(
  ["net.bridge.bridge-nf-call-iptables"]="1"
  ["net.bridge.bridge-nf-call-ip6tables"]="1"
  ["net.ipv4.ip_forward"]="1"
  ["fs.inotify.max_user_instances"]="1024"
  ["fs.inotify.max_user_watches"]="524288"
  ["vm.max_map_count"]="1048576"
)

sysctl_updated=false
for param in "${!sysctl_params[@]}"; do
  val="${sysctl_params[$param]}"
  
  # 현재 커널에 반영된 라이브 값 확인
  current_live_val=$(sysctl -n "$param" 2>/dev/null || echo "")
  
  # 설정 파일 내 값 확인 (정확한 매칭 검사)
  if grep -qE "^${param//./\.}[[:space:]]*=[[space:]]*${val}" "$SYSCTL_CONF" && [ "$current_live_val" = "$val" ]; then
    echo "-> 이미 $param 값은 $val 로 설정되어 있으며 적용된 상태입니다."
  else
    # 기존 설정이 존재하면 지우고 새로 추가
    sed -i "/^${param//./\.}/d" "$SYSCTL_CONF"
    echo "${param} = ${val}" >> "$SYSCTL_CONF"
    echo "-> $SYSCTL_CONF에 ${param} = ${val} 설정을 업데이트했습니다."
    sysctl_updated=true
  fi
done

if [ "$sysctl_updated" = true ]; then
  sysctl --system > /dev/null
  echo "-> 새로운 sysctl 설정을 커널에 즉시 반영했습니다."
else
  echo "-> 커널 반영을 위한 추가 sysctl 로드가 불필요합니다."
fi

# 4. 호스트 루트 마운트 전파 속성을 rshared로 활성화 (CNI, node-exporter 등의 HostPath 마운트 오류 방지)
echo "[4/4] 호스트 루트 마운트 공유 설정 (mount --make-rshared /)"
if ! findmnt -o PROPAGATION / | grep -q "shared"; then
  mount --make-rshared /
  echo "-> 호스트 루트 마운트를 rshared(공유) 상태로 변경했습니다."
else
  echo "-> 이미 호스트 루트 마운트가 shared 상태입니다."
fi

echo "============================================================="
echo "노드 준비 작업이 완료되었습니다!"
echo "============================================================="
