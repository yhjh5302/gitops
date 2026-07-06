#!/usr/bin/env bash
set -euo pipefail

# 스크립트 디렉토리 파악
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENV_FILE="${REPO_ROOT}/infra/common/vault-config.env"

echo "============================================================="
# 1. 템플릿 복사 (파일이 없을 때만 새 파일로 생성)
if [ ! -f "${ENV_FILE}" ]; then
  echo "1단계: vault-config.env 파일이 없어 템플릿으로부터 복사 생성 중..."
  cp "${REPO_ROOT}/infra/common/vault-config.env.template" "${ENV_FILE}"
else
  echo "1단계: 기존 vault-config.env 파일이 존재하여 덮어쓰기 치환 모드로 진행합니다."
fi

# 2. 패스워드용 안전한 난수 생성
echo "2단계: 보안 난수 패스워드 생성 중..."
POSTGRES_PASS=$(openssl rand -hex 16)
KEYCLOAK_DB_PASS=$(openssl rand -hex 16)
KEYCLOAK_ADMIN_PASS=$(openssl rand -hex 16)
MLFLOW_DB_PASS=$(openssl rand -hex 16)
ARGO_DB_PASS=$(openssl rand -hex 16)
REDIS_PASS=$(openssl rand -hex 16)
OAUTH2_CLIENT_SECRET_VAL=$(openssl rand -hex 16)
OAUTH2_COOKIE_SECRET_VAL=$(openssl rand -base64 32 | tr -d '\n')
ARGOCD_CLIENT_SECRET_VAL=$(openssl rand -hex 16)
GRAFANA_CLIENT_SECRET_VAL=$(openssl rand -hex 16)
ARGO_WORKFLOWS_CLIENT_SECRET_VAL=$(openssl rand -hex 16)
PRIVATE_ASSISTANT_DB_PASS=$(openssl rand -hex 16)

# 3. env 파일의 특정 비밀번호 라인들만 덮어쓰기 치환 (GITHUB_APP 관련 설정 보존)
echo "3단계: vault-config.env에 난수 주입 중..."
sed -i "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=\"${POSTGRES_PASS}\"#g" "${ENV_FILE}"
sed -i "s#^KEYCLOAK_DB_USERNAME=.*#KEYCLOAK_DB_USERNAME=\"keycloak\"#g" "${ENV_FILE}"
sed -i "s#^KEYCLOAK_DB_PASSWORD=.*#KEYCLOAK_DB_PASSWORD=\"${KEYCLOAK_DB_PASS}\"#g" "${ENV_FILE}"
sed -i "s#^KEYCLOAK_ADMIN_USERNAME=.*#KEYCLOAK_ADMIN_USERNAME=\"yhjh5302@gmail.com\"#g" "${ENV_FILE}"
sed -i "s#^KEYCLOAK_ADMIN_PASSWORD=.*#KEYCLOAK_ADMIN_PASSWORD=\"${KEYCLOAK_ADMIN_PASS}\"#g" "${ENV_FILE}"
sed -i "s#^MLFLOW_DB_USERNAME=.*#MLFLOW_DB_USERNAME=\"mlflow\"#g" "${ENV_FILE}"
sed -i "s#^MLFLOW_DB_PASSWORD=.*#MLFLOW_DB_PASSWORD=\"${MLFLOW_DB_PASS}\"#g" "${ENV_FILE}"
sed -i "s#^ARGO_DB_USERNAME=.*#ARGO_DB_USERNAME=\"argo_workflows\"#g" "${ENV_FILE}"
sed -i "s#^ARGO_DB_PASSWORD=.*#ARGO_DB_PASSWORD=\"${ARGO_DB_PASS}\"#g" "${ENV_FILE}"
sed -i "s#^PRIVATE_ASSISTANT_DB_PASSWORD=.*#PRIVATE_ASSISTANT_DB_PASSWORD=\"${PRIVATE_ASSISTANT_DB_PASS}\"#g" "${ENV_FILE}"
sed -i "s#^REDIS_PASSWORD=.*#REDIS_PASSWORD=\"${REDIS_PASS}\"#g" "${ENV_FILE}"
sed -i "s#^OAUTH2_CLIENT_SECRET=.*#OAUTH2_CLIENT_SECRET=\"${OAUTH2_CLIENT_SECRET_VAL}\"#g" "${ENV_FILE}"
sed -i "s#^OAUTH2_COOKIE_SECRET=.*#OAUTH2_COOKIE_SECRET=\"${OAUTH2_COOKIE_SECRET_VAL}\"#g" "${ENV_FILE}"
sed -i "s#^OAUTH2_CLIENT_ID=.*#OAUTH2_CLIENT_ID=\"platform\"#g" "${ENV_FILE}"
sed -i "s#^ARGOCD_CLIENT_SECRET=.*#ARGOCD_CLIENT_SECRET=\"${ARGOCD_CLIENT_SECRET_VAL}\"#g" "${ENV_FILE}"
sed -i "s#^GRAFANA_CLIENT_SECRET=.*#GRAFANA_CLIENT_SECRET=\"${GRAFANA_CLIENT_SECRET_VAL}\"#g" "${ENV_FILE}"
sed -i "s#^ARGO_WORKFLOWS_CLIENT_SECRET=.*#ARGO_WORKFLOWS_CLIENT_SECRET=\"${ARGO_WORKFLOWS_CLIENT_SECRET_VAL}\"#g" "${ENV_FILE}"

echo "============================================================="
echo "✓ 비밀번호 생성 완료! vault-config.env 생성 및 덮어쓰기가 완료되었습니다."
echo "============================================================="
