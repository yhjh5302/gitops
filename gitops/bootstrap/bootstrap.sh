#!/usr/bin/env bash

# 스크립트 실행 중 에러 발생 시 즉시 중단
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CRD_DIR="${SCRIPT_DIR}/crds"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

echo "============================================================="
echo "GitOps 및 MLOps 플랫폼 부트스트랩 스크립트"
echo "============================================================="

# 1단계: 필수 툴 존재 여부 확인
echo "1단계: 필수 CLI 도구 확인"
for cmd in helm kubectl curl python3; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "오류: 필수 도구 '${cmd}'가 설치되어 있지 않습니다."
    exit 1
  fi
done
echo "확인 완료."

# 2단계: Helm 레포지토리 등록 및 업데이트
echo "2단계: Helm Repository 등록 및 업데이트"
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

# 3단계: CRD 디렉토리 생성 및 로컬 차트로부터 추출
echo "3단계: 핵심 CRD 파일 추출 및 확보 (${CRD_DIR})"
mkdir -p "${CRD_DIR}"
SYS_DIR="${REPO_ROOT}/gitops/shared-charts"

# A. Gateway API CRD (v1.5.1 - Experimental for UDPRoute support)
echo " -> Gateway API CRD 복사 중..."
cp "${SCRIPT_DIR}/static-crds/gateway-api-crds.yaml" "${CRD_DIR}/gateway-api-crds.yaml"

# B. Argo Workflows CRD (로컬 차트 추출)
echo " -> Argo Workflows CRD 추출 중..."
cat "${SYS_DIR}/argo-workflows/files/crds/minimal"/*.yaml > "${CRD_DIR}/argo-workflows-crds.yaml"



# D. Kyverno CRD (로컬 차트 추출)
echo " -> Kyverno CRD 추출 중..."
helm template kyverno "${SYS_DIR}/kyverno" --set crds.install=true | python3 -c "import sys; print('\n---\n'.join([b for b in sys.stdin.read().split('\n---\n') if 'kind: CustomResourceDefinition' in b]))" > "${CRD_DIR}/kyverno-crds.yaml"

# E. VictoriaMetrics Operator CRD (로컬 서브차트 crd.yaml 복사)
echo " -> VictoriaMetrics Operator CRD 복사 중..."
cat "${SYS_DIR}/victoria-metrics/charts/victoria-metrics-operator/crd.yaml" > "${CRD_DIR}/vm-crds.yaml"

# F. NVIDIA GPU Operator CRD (로컬 차트 추출)
echo " -> NVIDIA GPU Operator CRD 추출 중..."
helm show crds "${SYS_DIR}/gpu-operator" > "${CRD_DIR}/gpu-operator-crds.yaml"

# G. NVIDIA DRA Driver CRD (로컬 차트 추출)
echo " -> NVIDIA DRA Driver CRD 추출 중..."
helm show crds "${SYS_DIR}/nvidia-dra-driver" > "${CRD_DIR}/nvidia-dra-crds.yaml"

# H. K-Gateway CRD (로컬 kgateway-crds templates 렌더링)
echo " -> K-Gateway CRD 렌더링 중..."
helm template "${SYS_DIR}/kgateway/charts/kgateway-crds" > "${CRD_DIR}/kgateway-crds.yaml"

# I. Istio CRD (로컬 base 차트 추출)
echo " -> Istio CRD 추출 중..."
if [ -f "${SYS_DIR}/istio/charts/base/files/crd-all.gen.yaml" ]; then
  cp "${SYS_DIR}/istio/charts/base/files/crd-all.gen.yaml" "${CRD_DIR}/istio-crds.yaml"
else
  echo " ⚠️ Istio 로컬 차트 CRD 파일이 존재하지 않습니다. CRD 추출을 건너뜁니다."
fi




# 4단계: 파이썬 스크립트를 통한 안전 어노테이션 주입
# yaml 파싱 라이브러리 없이 표준 라이브러리로 문자열 조작하여 어노테이션 추가
echo "4단계: CRD 삭제 방지 어노테이션 강제 주입"
python3 - <<EOF
import os
import re

crd_dir = "${CRD_DIR}"
annotations = [
    '    helm.sh/resource-policy: keep',
    '    argocd.argoproj.io/sync-options: Prune=false,ServerSideApply=true'
]

for filename in os.listdir(crd_dir):
    if not filename.endswith('.yaml'):
        continue
    
    filepath = os.path.join(crd_dir, filename)
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # 각 YAML 문서의 CustomResourceDefinition 메타데이터 영역에 어노테이션 추가
    # 대형 파일의 안전한 파싱을 위해 정규식 및 라인 분석 활용
    documents = content.split('\n---')
    modified_documents = []
    
    for doc in documents:
        if 'kind: CustomResourceDefinition' in doc:
            # metadata: 라인 찾기
            lines = doc.split('\n')
            meta_index = -1
            for i, line in enumerate(lines):
                if line.rstrip() == 'metadata:':
                    meta_index = i
                    break
            
            if meta_index != -1:
                # metadata 하위에 annotations: 추가
                # 이미 annotations가 있는 경우 및 신규 추가 처리
                has_ann = False
                for j in range(meta_index + 1, len(lines)):
                    if lines[j].startswith('  ') and not lines[j].startswith('    '):
                        if lines[j].strip().startswith('annotations:'):
                            has_ann = True
                            ann_index = j
                            if lines[j].rstrip().endswith('{}'):
                                lines[j] = lines[j].replace('{}', '').rstrip()
                            elif j + 1 < len(lines) and lines[j+1].strip() == '{}':
                                del lines[j+1]
                            break
                    if not lines[j].startswith('  ') and lines[j].strip() != '':
                        break
                
                if has_ann:
                    # 기존 annotations 블록 아래에 추가
                    for ann in annotations:
                        lines.insert(ann_index + 1, ann)
                else:
                    # 신규 annotations 블록 생성
                    lines.insert(meta_index + 1, '  annotations:')
                    for k, ann in enumerate(annotations):
                        lines.insert(meta_index + 2 + k, ann)
                
                doc = '\n'.join(lines)
        modified_documents.append(doc)
    
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write('\n---'.join(modified_documents))
    print(f" -> {filename} 어노테이션 주입 완료.")
EOF

# 5단계: CRD 클러스터 배포
echo "5단계: 보호된 CRD 클러스터에 배포"
kubectl apply --server-side --force-conflicts -f "${CRD_DIR}/"

# 6단계: 코어 인프라 솔루션 상태 확인 (setup-addons.sh 완료 여부 검증)
echo "6단계: 코어 인프라 솔루션 상태 확인"
if ! kubectl get crd clustersecretstores.external-secrets.io &>/dev/null; then
  echo -e "${RED}오류: 필수 인프라 애드온(External Secrets Operator 등)이 설치되어 있지 않습니다.${NC}" >&2
  echo -e "${RED}먼저 'infra/common/setup-addons.sh'를 실행하여 CNI 및 필수 애드온 설치를 완료해주세요.${NC}" >&2
  exit 1
fi

# 7단계: Argo CD 설치 및 구성 (argocd 네임스페이스)
echo "7단계: Argo CD 설치 및 구성"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# A. GitHub App 레포지토리 자격증명 ExternalSecret 생성
echo " -> Vault 연동을 위한 GitHub App ExternalSecret 배포 중..."
kubectl apply -f "${SCRIPT_DIR}/manifests/argocd-repo-secret.yaml"

# K8s Secret이 생성될 때까지 대기
echo " -> External Secrets가 Vault에서 github-app-repo 시크릿을 동기화하기를 대기합니다..."
retries=30
while [ $retries -gt 0 ]; do
  if kubectl get secret -n argocd gitops-github-app-repo &>/dev/null; then
    echo " -> ✓ gitops-github-app-repo Secret 생성 완료!"
    break
  fi
  sleep 2
  retries=$((retries-1))
done

# B. Argo CD 설치 진행
echo " -> 멱등성 보장을 위해 기존 ConfigMap에 Helm 릴리즈 메타데이터 패치..."
kubectl label configmap -n argocd argocd-cm argocd-rbac-cm app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
kubectl annotate configmap -n argocd argocd-cm argocd-rbac-cm meta.helm.sh/release-name=argocd meta.helm.sh/release-namespace=argocd --overwrite 2>/dev/null || true

helm upgrade --install argocd argo/argo-cd \
  --version 10.1.0 \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --set configs.params."server\.insecure"=true \
  --set dex.enabled=false \
  --wait --timeout 5m

# C. Webhook 검증용 ExternalSecret 배포 (argocd-secret에 머지)
echo " -> Vault 연동을 위한 Webhook ExternalSecret 배포 중..."
kubectl apply -f "${SCRIPT_DIR}/manifests/argocd-webhook-secret.yaml"

# 5초 대기 후 argocd-server 롤아웃 재시작 (웹훅 시크릿 캐시 반영)
sleep 5
echo " -> 웹훅 시크릿 변경으로 인한 argocd-server 재시작 중..."
kubectl rollout restart deployment/argocd-server -n argocd

# 7단계: Argo CD 어드민 비밀번호 출력
echo "============================================================="
echo "Argo CD 설치 완료!"
echo "ID: admin"
echo -n "Initial Password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
echo "URL: https://argocd.jin-server.com"
echo "============================================================="

# 8단계: Root ApplicationSet 자동 배포 (기존 리소스 초기화 포함)
echo -e "\n${GREEN}8단계: Root ApplicationSet 자동 배포${NC}"
MAIN_APPSET="${REPO_ROOT}/gitops/00-root-app/main-applicationset.yaml"
SUB_APPSET="${REPO_ROOT}/gitops/00-root-app/sub-applicationset.yaml"

if [ -f "${MAIN_APPSET}" ] && [ -f "${SUB_APPSET}" ]; then
  # 1. Main ApplicationSet Prune & Apply
  if kubectl get applicationset platform-main-applicationset -n argocd &>/dev/null; then
    echo " -> 기존 platform-main-applicationset이 감지되어 삭제(Prune) 초기화를 진행합니다..."
    kubectl delete -f "${MAIN_APPSET}"
    sleep 5
  fi
  # 2. Sub ApplicationSet Prune & Apply
  if kubectl get applicationset platform-sub-applicationset -n argocd &>/dev/null; then
    echo " -> 기존 platform-sub-applicationset이 감지되어 삭제(Prune) 초기화를 진행합니다..."
    kubectl delete -f "${SUB_APPSET}"
    sleep 5
  fi
  
  echo " -> 삭제 완료 대기 중 (15초)..."
  sleep 15

  echo " -> Main/Sub ApplicationSet을 클러스터에 배포합니다..."
  kubectl apply -f "${MAIN_APPSET}"
  kubectl apply -f "${SUB_APPSET}"
  echo " -> ✓ platform-main 및 platform-sub Applicationset 자동 배포 완료!"
else
  echo -e "${RED}오류: ApplicationSet 파일들을 찾을 수 없어 배포를 진행할 수 없습니다.${NC}" >&2
  exit 1
fi

# 9단계: ExternalSecret 즉시 동기화 트리거
echo -e "\n${GREEN}9단계: ExternalSecret 즉시 동기화 트리거${NC}"
echo " -> 네임스페이스 및 ExternalSecret이 등록될 때까지 15초 대기..."
sleep 15
NAMESPACES=("postgres" "keycloak" "mlflow" "argo-workflows" "redis" "oauth2-proxy" "private-assistant" "cozyvoice-serving" "whisper-serving" "qwen-serving")
for ns in "${NAMESPACES[@]}"; do
  kubectl annotate externalsecret -n "${ns}" --all force-sync=$(date +%s) --overwrite &>/dev/null || true
done
echo " -> ✓ 모든 ExternalSecret의 즉시 동기화가 성공적으로 시작되었습니다."
echo "============================================================="

