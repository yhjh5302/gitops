#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}     External Secrets Operator 인프라 레벨 설치 스크립트     ${NC}"
echo -e "${BLUE}=============================================================${NC}"

if ! command -v helm &>/dev/null; then
  echo -e "${RED}오류: Helm CLI가 설치되어 있지 않습니다.${NC}" >&2
  exit 1
fi

echo -e "${GREEN}1단계: External Secrets Operator Helm Repository 등록${NC}"
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm repo update external-secrets

echo -e "\n${GREEN}2단계: External Secrets Operator 설치 (2.7.0)${NC}"
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version 2.7.0 \
  --set installCRDs=true \
  --wait --timeout 5m

# Pod 준비 완료 대기
echo " -> External Secrets Pod들이 준비 완료 상태가 될 때까지 대기합니다..."
kubectl wait --namespace external-secrets --for=condition=Ready pod -l app.kubernetes.io/instance=external-secrets --timeout=5m

echo -e "\n${GREEN}3단계: Vault에 Kubernetes Auth 백엔드 구성 (외부 시크릿 연동)${NC}"
# Vault 헬퍼 명령어 실행 (K8s API 서버 주소 연동 및 Policy/Role 정의)
if kubectl get pod -n vault vault-0 &>/dev/null; then
  echo " -> Vault 내부 Kubernetes 인증 엔진 활성화 및 설정 중..."
  
  # Kubernetes Auth Engine 활성화 (에러가 나도 이미 활성화된 상태면 패스하도록 구성)
  kubectl exec -n vault vault-0 -- vault auth enable kubernetes 2>/dev/null || true
  
  # Kubernetes Auth Engine 상세 구성
  kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443" \
    disable_iss_validation=true &>/dev/null

  # External Secrets가 읽을 권한을 지정할 Policy 정의
  echo " -> Vault Policy (eso-policy) 작성 중..."
  kubectl exec -i -n vault vault-0 -- vault policy write eso-policy - <<EOF &>/dev/null
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

  # External Secrets ServiceAccount에 바인딩할 Role 정의
  echo " -> Vault Role (eso-role) 구성 중..."
  kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/eso-role \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=eso-policy \
    ttl=24h &>/dev/null

  echo " -> ✓ Vault에 Kubernetes Auth 백엔드가 성공적으로 연결되었습니다."
else
  echo -e "${RED} ⚠️ 경고: vault-0 Pod를 찾을 수 없어 Vault Auth 설정을 건너뜁니다.${NC}"
fi

echo -e "\n${GREEN}4단계: ClusterSecretStore 리소스 생성 (vault-backend)${NC}"
# ClusterSecretStore 정의 배포
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso-role"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
EOF

echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}External Secrets Operator 및 ClusterSecretStore 구성 완료!${NC}"
echo -e "${GREEN}=============================================================${NC}"
