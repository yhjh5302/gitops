#!/usr/bin/env bash

# 스크립트 실행 중 에러 발생 시 즉시 중단
set -euo pipefail

# SCRIPT_DIR와 REPO_ROOT 설정
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================="
echo "1단계: 기존 sub-cluster 확인 및 삭제"
if kind get clusters 2>/dev/null | grep -q "^sub-cluster$"; then
  echo -e "\033[0;33m[경고] 기존 sub-cluster 클러스터가 이미 존재합니다.\033[0m"
  echo -e "\033[0;31m재설치 시 기존 클러스터가 영구 삭제되고 모든 데이터가 소멸됩니다.\033[0m"
  read -p "기존 클러스터를 삭제하고 재설치하시겠습니까? (y/N): " delete_choice
  if [[ ! "$delete_choice" =~ ^[Yy]$ ]]; then
    echo "작업이 취소되었습니다."
    exit 0
  fi
  kind delete cluster --name sub-cluster
else
  echo " -> 기존에 생성된 sub-cluster가 없습니다. 생성을 진행합니다."
fi

echo "============================================================="
echo "2단계: 새로운 sub-cluster 생성"

CONFIG_FILE="${SCRIPT_DIR}/kind-config.yaml"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "오류: 설정 파일(${CONFIG_FILE})을 찾을 수 없습니다." >&2
  exit 1
fi

# 클러스터 생성 실행
kind create cluster \
  --config "${CONFIG_FILE}" \
  --name sub-cluster

echo "============================================================="
echo "Kind 클러스터 생성 완료!"
echo "kubeconfig 컨텍스트가 'kind-sub-cluster'로 설정되었습니다."
echo "다음 단계: 필수 애드온(CNI 등) 설치를 위해 'infra/common/setup-addons.sh'를 실행하세요."
echo "============================================================="
