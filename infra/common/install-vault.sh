#!/usr/bin/env bash

# eBPF 기반 또는 로컬 호스트용 HashiCorp Vault 설치 스크립트
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="${SCRIPT_DIR}/vault-keys.json"

GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}        HashiCorp Vault 운영 환경 고가용성(Raft) 설치 스크립트       ${NC}"
echo -e "${BLUE}=============================================================${NC}"

if ! command -v helm &>/dev/null; then
  echo -e "${RED}오류: Helm CLI가 설치되어 있지 않습니다.${NC}" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}오류: 이 스크립트를 기동하려면 'jq' 도구가 필요합니다. 먼저 설치해주세요.${NC}" >&2
  exit 1
fi

echo -e "${GREEN}1단계: HashiCorp Helm Repository 등록${NC}"
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm repo update hashicorp

echo -e "\n${GREEN}2단계: Vault 설치 (Raft Backend 및 StatefulSet PVC 활성화)${NC}"
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

# Webhook 충돌 오류 방지를 위해 기존 MutatingWebhookConfiguration 삭제
kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg --ignore-not-found=true &>/dev/null

# 단중화 최적화: 복제본(replicas)을 1개로 고정하여 단일 Pod로 구동합니다.
echo " -> Vault 복제본(replicas)을 1개로 설정하여 단중화(Standalone)로 구성합니다."

VAULT_RAFT_CONFIG=$(cat <<EOF
ui = true

listener "tcp" {
  tls_disable = 1
  address = "[::]:8200"
  cluster_address = "[::]:8201"
}

storage "raft" {
  path = "/vault/data"
}

service_registration "kubernetes" {}

telemetry {
  prometheus_retention_time = "15s"
  disable_hostname = true
}

disable_mlock = true
EOF
)

# 사전에 저장된 키가 있는 경우 vault-unseal-key Secret 사전 생성 (postStart 훅 연동용)
if [ -f "${KEY_FILE}" ]; then
  PRE_UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${KEY_FILE}" 2>/dev/null || echo "")
  if [ -n "${PRE_UNSEAL_KEY}" ]; then
    kubectl create secret generic vault-unseal-key -n vault --from-literal=key="${PRE_UNSEAL_KEY}" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null || true
  fi
fi

EXTRA_VAULT_ARGS=(
  "--set" "server.ha.replicas=1"
  "--set" "server.ha.raft.config=${VAULT_RAFT_CONFIG}"
)

# 운영 환경 모드 설정:
# server.dev.enabled=false (개발 모드 비활성화)
# server.ha.enabled=true & server.ha.raft.enabled=true (Raft 백엔드 기동)
# server.dataStorage.enabled=true (물리 PVC 동적 볼륨 매핑)
# --wait 옵션은 Unseal이 끝나야 Pod가 Ready가 되므로, Helm 단계에선 대기하지 않고 스크립트에서 제어합니다.
helm upgrade --install vault hashicorp/vault \
  --version 0.34.1 \
  --namespace vault \
  --set "server.dev.enabled=false" \
  --set "server.ha.enabled=true" \
  --set "server.ha.raft.enabled=true" \
  --set "server.ha.raft.setNodeId=true" \
  --set "server.dataStorage.enabled=true" \
  --set "server.dataStorage.size=10Gi" \
  --set "server.service.type=ClusterIP" \
  "${EXTRA_VAULT_ARGS[@]}"

echo -e "\n${GREEN}3단계: Vault Pod 기동 및 초기화/Unseal 자동화${NC}"

# OnDelete 전략으로 인해 파드가 이전 이미지로 남아있는 경우 새 이미지 반영을 위해 파드 롤링 재시작
CURRENT_POD_IMG=$(kubectl get pod vault-0 -n vault -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || echo "")
TARGET_IMG=$(kubectl get statefulset vault -n vault -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if [ -n "${CURRENT_POD_IMG}" ] && [ -n "${TARGET_IMG}" ] && [ "${CURRENT_POD_IMG}" != "${TARGET_IMG}" ]; then
  echo " -> Vault 이미지 업데이트 감지 (${CURRENT_POD_IMG} -> ${TARGET_IMG}). vault-0 Pod를 재시작합니다..."
  kubectl delete pod vault-0 -n vault --wait=true
fi

echo " -> Vault Pod(vault-0)가 API 서버에 등록될 때까지 대기합니다..."
for i in {1..30}; do
  if kubectl get pod -n vault vault-0 --request-timeout='1s' &>/dev/null; then
    break
  fi
  sleep 1
done

echo " -> Vault Pod(vault-0)가 실행(Running)될 때까지 대기합니다..."
kubectl wait --namespace vault --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=5m

# 설치 디렉토리 기준 키 저장 파일 정의
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="${SCRIPT_DIR}/vault-keys.json"

# 초기화 상태 체크
VAULT_STATUS=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || true)
INIT_STATUS=$(echo "${VAULT_STATUS}" | jq -r '.initialized' 2>/dev/null || echo "false")

if [ "${INIT_STATUS}" != "True" ] && [ "${INIT_STATUS}" != "true" ]; then
  echo " -> Vault 초기화가 되어있지 않습니다. 초기화를 수행합니다..."
  # 로컬 개발/검증을 위해 1개의 키 마스터 쉐어로 간소화 초기화
  INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json 2>/dev/null || true)
  if [ -n "${INIT_OUTPUT}" ] && echo "${INIT_OUTPUT}" | jq -e '.unseal_keys_b64' &>/dev/null; then
    echo "${INIT_OUTPUT}" > "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
    echo " -> [성공] Vault 초기화 완료. 마스터 키와 토큰이 ${KEY_FILE}에 저장되었습니다."
    POST_UNSEAL_KEY=$(echo "${INIT_OUTPUT}" | jq -r '.unseal_keys_b64[0]' 2>/dev/null || echo "")
    kubectl create secret generic vault-unseal-key -n vault --from-literal=key="${POST_UNSEAL_KEY}" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null || true
  fi
fi

# vault-keys.json 파일에서 마스터 키 및 루트 토큰 추출
if [ -f "${KEY_FILE}" ]; then
  UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${KEY_FILE}" 2>/dev/null || echo "")
  ROOT_TOKEN=$(jq -r '.root_token' "${KEY_FILE}" 2>/dev/null || echo "")

  echo " -> Vault Unseal을 수행 중..."
  kubectl exec -n vault vault-0 -- vault operator unseal "${UNSEAL_KEY}" &>/dev/null

  echo " -> Vault 루트 토큰 로그인 중..."
  kubectl exec -n vault vault-0 -- vault login token="${ROOT_TOKEN}" &>/dev/null
else
  echo -e "${RED}오류: Vault 초기화 키 파일(${KEY_FILE})을 찾을 수 없어 Unseal을 중단합니다.${NC}" >&2
  exit 1
fi

# 4단계: KV Secret Engine 활성화 및 자격증명 적재
echo -e "\n${GREEN}4단계: KV Engine 활성화 및 초기 시크릿 적재${NC}"

# 운영 모드에서는 기본 kv 엔진인 'secret/'이 없으므로 직접 활성화
if ! kubectl exec -n vault vault-0 -- vault secrets list -format=json 2>/dev/null | jq -e 'has("secret/")' &>/dev/null; then
  echo " -> KV Secrets Engine (v2)을 secret/ 경로에 구성하는 중..."
  kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2 &>/dev/null
fi

CONFIG_FILE="${SCRIPT_DIR}/vault-config.env"
if [ -f "${CONFIG_FILE}" ]; then
  echo " -> vault-config.env 파일을 읽어 Vault에 적재하는 중..."
  source "${CONFIG_FILE}"

  # Vault에 GitHub App 정보 주입
  kubectl exec -n vault vault-0 -- vault kv put secret/gitops/github-app \
    url="${REPO_URL:-}" \
    githubAppID="${GITHUB_APP_ID:-}" \
    githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID:-}" \
    githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY:-}" &>/dev/null

  # Vault에 Webhook 비밀키 주입
  kubectl exec -n vault vault-0 -- vault kv put secret/gitops/argocd-webhook \
    webhook.github.secret="${WEBHOOK_SECRET:-}" &>/dev/null

  # Vault에 데이터베이스 및 애플리케이션 비밀번호 주입
  echo " -> 데이터베이스 및 애플리케이션용 시크릿을 Vault에 적재하는 중..."
  kubectl exec -n vault vault-0 -- vault kv put secret/postgres postgres-password="${POSTGRES_PASSWORD:-postgres_pass}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/mlflow database-username="${MLFLOW_DB_USERNAME:-mlflow}" database-password="${MLFLOW_DB_PASSWORD:-mlflow_pass}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/redis redis-password="${REDIS_PASSWORD:-redis_pass}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/keycloak admin-username="${KEYCLOAK_ADMIN_USERNAME:-yhjh5302@gmail.com}" admin-password="${KEYCLOAK_ADMIN_PASSWORD:-keycloak_admin_pass}" database-password="${KEYCLOAK_DB_PASSWORD:-keycloak_pass}" trusted-addresses="${TRUSTED_ADDRESSES:-10.233.0.0/16,127.0.0.0/8}" google-client-id="${GOOGLE_CLIENT_ID:-}" google-client-secret="${GOOGLE_CLIENT_SECRET:-}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/argo-workflows database-username="${ARGO_DB_USERNAME:-argo_workflows}" database-password="${ARGO_DB_PASSWORD:-argo_workflows_pass}" client-secret="${ARGO_WORKFLOWS_CLIENT_SECRET:-argo_workflows_client_secret_placeholder}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/oauth2-proxy client-id="${OAUTH2_CLIENT_ID:-platform}" client-secret="${OAUTH2_CLIENT_SECRET:-oauth2_client_secret_placeholder}" cookie-secret="${OAUTH2_COOKIE_SECRET:-oauth2_cookie_secret_placeholder_long_string}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/argocd client-secret="${ARGOCD_CLIENT_SECRET:-argocd_client_secret_placeholder}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/grafana client-secret="${GRAFANA_CLIENT_SECRET:-grafana_client_secret_placeholder}" admin-password="${GRAFANA_ADMIN_PASSWORD:-}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/private-assistant huggingface-token="${HF_TOKEN:-huggingface_token_placeholder}" db-user="${PRIVATE_ASSISTANT_DB_USERNAME:-private_assistant}" database-password="${PRIVATE_ASSISTANT_DB_PASSWORD:-}" &>/dev/null
  kubectl exec -n vault vault-0 -- vault kv put secret/versus-incident gateway-secret="${VERSUS_GATEWAY_SECRET:-$(openssl rand -hex 32)}" ai-api-key="${VERSUS_AI_API_KEY:-$(openssl rand -hex 16)}" &>/dev/null

  # Victoria Metrics용 Prometheus 메트릭 수집 정책 및 토큰 구성
  echo " -> Victoria Metrics용 Prometheus 메트릭 수집 정책 및 토큰 구성 중..."
  kubectl exec -i -n vault vault-0 -- vault policy write prometheus-metrics - <<'EOF' &>/dev/null
path "sys/metrics" {
  capabilities = ["read", "list"]
}
EOF
  # 기존 토큰 유무 확인 후 없을 때만 장기(orphan) 토큰 발급 및 적재
  if ! kubectl exec -n vault vault-0 -- vault kv get -field=token secret/victoria-metrics/vault-token &>/dev/null; then
    METRICS_TOKEN=$(kubectl exec -n vault vault-0 -- vault token create -policy=prometheus-metrics -period=87600h -orphan -field=token 2>/dev/null || echo "")
    if [ -n "${METRICS_TOKEN}" ]; then
      kubectl exec -n vault vault-0 -- vault kv put secret/victoria-metrics/vault-token token="${METRICS_TOKEN}" &>/dev/null
      echo " -> ✓ Victoria Metrics 메트릭 수집용 Vault 토큰 적재 완료."
    fi
  else
    echo " -> ✓ Victoria Metrics용 메트릭 수집 토큰이 이미 존재합니다."
  fi

  echo " -> ✓ 자격증명, 웹훅 및 데이터베이스 시크릿이 Vault에 안전하게 적재되었습니다."
else
  echo " ⚠️ 경고: [infra/common/vault-config.env] 파일이 존재하지 않아 Vault 초기 적재를 건너뜁니다."
fi

echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}Vault가 성공적으로 설치 및 초기화되었습니다! (Production Mode - Raft)${NC}"
echo -e "${GREEN}마스터 키 보안 정보 보관처: ${KEY_FILE}${NC}"
echo -e "${GREEN}=============================================================${NC}"
