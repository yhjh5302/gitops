#!/usr/bin/env bash

# HashiCorp Vault (vault-0) 수동 Unseal 편의 스크립트
set -euo pipefail

BLUE='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="${SCRIPT_DIR}/vault-keys.json"

if [ ! -f "${KEY_FILE}" ]; then
  echo -e "${RED}오류: Vault 키 파일(${KEY_FILE})이 존재하지 않습니다.${NC}" >&2
  exit 1
fi

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${KEY_FILE}" 2>/dev/null || echo "")

if [ -z "${UNSEAL_KEY}" ] || [ "${UNSEAL_KEY}" = "null" ]; then
  echo -e "${RED}오류: ${KEY_FILE} 파일에서 unseal_keys_b64 키를 읽어오지 못했습니다.${NC}" >&2
  exit 1
fi

echo -e "${BLUE}Vault(vault-0) 봉인 해제(Unseal)를 시작합니다...${NC}"
if kubectl exec -n vault vault-0 -- vault operator unseal "${UNSEAL_KEY}"; then
  echo -e "${GREEN}✓ Vault Unseal 성공!${NC}"
else
  echo -e "${RED}⚠️ Vault Unseal 실패.${NC}" >&2
  exit 1
fi
