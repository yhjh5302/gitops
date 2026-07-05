#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}        Cert Manager 인프라 레벨 설치 스크립트                ${NC}"
echo -e "${BLUE}=============================================================${NC}"

if ! command -v helm &>/dev/null; then
  echo -e "${RED}오류: Helm CLI가 설치되어 있지 않습니다.${NC}" >&2
  exit 1
fi

echo -e "${GREEN}1단계: Jetstack Helm Repository 등록${NC}"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

echo -e "\n${GREEN}2단계: Cert Manager 설치 (v1.20.3, CRD 포함)${NC}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.20.3 \
  --set installCRDs=true \
  --wait --timeout 5m

echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}Cert Manager 설치 완료!${NC}"
echo -e "${GREEN}=============================================================${NC}"
