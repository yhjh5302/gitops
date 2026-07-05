#!/usr/bin/env bash
# Script to dashboard local vs remote Helm chart versions and optionally update them

set -euo pipefail

# Determine script location directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "========================================================================================================"
echo "                               GitOps System Components Version Dashboard"
echo "========================================================================================================"
printf "%-30s | %-28s | %-28s\n" "COMPONENTS" "LOCAL DEFINED (CHART / APP)" "HELM REPOSITORY (CHART / APP)"
printf "%-30s | %-28s | %-28s\n" "------------------------------" "----------------------------" "----------------------------"

# Chart Helm identifiers mapped to local system component directories
declare -A chart_map=(
  ["argo/argo-workflows"]="shared-charts/argo-workflows"
  ["nvidia/gpu-operator"]="shared-charts/gpu-operator"
  ["community-charts/mlflow"]="shared-charts/mlflow"
  ["helmforge/keycloak"]="shared-charts/keycloak"
  ["kyverno/kyverno"]="shared-charts/kyverno"
  ["victoria-metrics/victoria-metrics-k8s-stack"]="shared-charts/victoria-metrics"
  ["victoria-metrics/victoria-logs-cluster"]="shared-charts/victoria-logs"
  ["vector/vector"]="shared-charts/vector"
  ["oauth2-proxy/oauth2-proxy"]="shared-charts/oauth2-proxy"
  ["kgateway"]="shared-charts/kgateway/charts/kgateway"
  ["nvidia-dra-driver"]="shared-charts/nvidia-dra-driver"
  ["open-telemetry/opentelemetry-collector"]="shared-charts/opentelemetry-collector"
  ["istio/base"]="shared-charts/istio/charts/base"
  ["istio/istiod"]="shared-charts/istio/charts/istiod"
  ["istio/cni"]="shared-charts/istio/charts/cni"
  ["istio/ztunnel"]="shared-charts/istio/charts/ztunnel"
  ["istio/gateway"]="shared-charts/istio/charts/gateway"
  ["gateway-api"]="../bootstrap/static-crds"
  ["metrics-server"]="01-system/main/metrics-server/manifests"
)

# Ordered keys for output alignment
keys=(
  "argo/argo-workflows"
  "nvidia/gpu-operator"
  "community-charts/mlflow"
  "helmforge/keycloak"
  "kyverno/kyverno"
  "victoria-metrics/victoria-metrics-k8s-stack"
  "victoria-metrics/victoria-logs-cluster"
  "vector/vector"
  "oauth2-proxy/oauth2-proxy"
  "kgateway"
  "nvidia-dra-driver"
  "open-telemetry/opentelemetry-collector"
  "istio/base"
  "istio/istiod"
  "istio/cni"
  "istio/ztunnel"
  "istio/gateway"
  "gateway-api"
  "metrics-server"
)

# To hold remote versions for update phase
declare -A remote_chart_versions
declare -A remote_app_versions

for key in "${keys[@]}"; do
  local_path="${GITOPS_DIR}/${chart_map[$key]}"
  
  # Determine correct Chart.yaml path (special handling for K-Gateway due to nested folders)
  chart_yaml="${local_path}/Chart.yaml"
  
  # 1. Parse local versions
  local_chart="N/A"
  local_app="N/A"
  if [ "$key" = "gateway-api" ]; then
    local_chart=$(grep -E "Source: https://github.com/kubernetes-sigs/gateway-api/releases/download/" "${GITOPS_DIR}/bootstrap/static-crds/gateway-api-crds.yaml" 2>/dev/null || true)
    local_chart=$(echo "$local_chart" | sed -E 's|.*/download/([^/]+)/.*|\1|')
    if [ -z "$local_chart" ]; then
      local_chart="v1.5.1"
    fi
    local_app="$local_chart"
  elif [ "$key" = "metrics-server" ]; then
    local_chart=$(grep -E "Source: https://github.com/kubernetes-sigs/metrics-server/releases/download/" "${local_path}/metrics-server.yaml" 2>/dev/null || true)
    local_chart=$(echo "$local_chart" | sed -E 's|.*/download/([^/]+)/.*|\1|')
    if [ -z "$local_chart" ]; then
      local_chart="v0.8.1"
    fi
    local_app="$local_chart"
  elif [ -f "$chart_yaml" ]; then
    local_chart=$(awk '/^version:/ {print $2; exit}' "$chart_yaml" | tr -d '"'\''')
    local_app=$(awk '/^appVersion:/ {print $2; exit}' "$chart_yaml" | tr -d '"'\''')
  fi
  local_display="${local_chart} / ${local_app}"

  # 2. Fetch remote repository versions (including static lookup for OCI charts)
  remote_chart="N/A"
  remote_app="N/A"
  
  if [ "$key" = "kgateway" ]; then
    # OCI-based K-Gateway static target update
    remote_chart="v2.3.5"
    remote_app="v2.3.5"
  elif [ "$key" = "nvidia-dra-driver" ]; then
    # OCI-based NVIDIA DRA Driver static target update
    remote_chart="0.4.1"
    remote_app="0.4.1"
  elif [ "$key" = "gateway-api" ]; then
    # Fetch latest Gateway API release version from GitHub
    remote_chart=$(curl -s "https://api.github.com/repos/kubernetes-sigs/gateway-api/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$remote_chart" ] || [[ ! "$remote_chart" =~ ^v[0-9] ]]; then
      remote_chart="v1.5.1" # fallback if rate limited or offline
    fi
    remote_app="$remote_chart"
  elif [ "$key" = "metrics-server" ]; then
    # Fetch latest metrics-server release version from GitHub
    remote_chart=$(curl -s "https://api.github.com/repos/kubernetes-sigs/metrics-server/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$remote_chart" ] || [[ ! "$remote_chart" =~ ^v[0-9] ]]; then
      remote_chart="v0.8.1" # fallback if rate limited or offline
    fi
    remote_app="$remote_chart"
  else
    result=$(helm search repo "$key" --max-col-width 100 2>/dev/null | grep "^$key[[:space:]]" | head -n 1)
    if [ -n "$result" ]; then
      read -r _ remote_chart remote_app _ <<< "$result"
    fi
  fi
  
  remote_display="${remote_chart} / ${remote_app}"
  remote_chart_versions["$key"]="$remote_chart"
  remote_app_versions["$key"]="$remote_app"

  # Pretty print alignment
  name_display="${key#*/}"
  printf "%-30s | %-28s | %-28s\n" "$name_display" "$local_display" "$remote_display"
done
echo "========================================================================================================"

# Interactive Update Prompt
echo
read -p "Would you like to pull and update the charts to their latest remote versions? (y/n): " answer
echo

# Helper function to pull and untar Helm charts, renaming the output directory to our local desired name
pull_and_extract_chart() {
  local repo_chart="$1"
  local target_dir="$2"
  local ver="$3"
  
  local target_path="${SCRIPT_DIR}/${target_dir}"
  rm -rf "$target_path"
  
  # Create a secure temporary workspace
  local temp_dir
  temp_dir=$(mktemp -d -p "${SCRIPT_DIR}")
  
  echo "    .. downloading and extracting $repo_chart..."
  helm pull "$repo_chart" --version "$ver" --untar --destination "$temp_dir" >/dev/null
  
  # Resolve untarred directory and rename to local naming convention
  local pulled_folder
  pulled_folder=$(find "$temp_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)
  
  if [ -n "$pulled_folder" ] && [ -d "$pulled_folder" ]; then
    mkdir -p "$(dirname "$target_path")"
    mv "$pulled_folder" "$target_path"
  else
    echo "❌ [Error] Failed to resolve pulled chart in $temp_dir" >&2
    rm -rf "$temp_dir"
    exit 1
  fi
  
  rm -rf "$temp_dir"
}

if [[ "$answer" =~ ^[Yy]$ ]]; then
  echo "============================================================="
  echo "               Starting Local Helm Charts Update"
  echo "============================================================="
  
  for key in "${keys[@]}"; do
    target_ver="${remote_chart_versions[$key]}"
    if [ "$target_ver" = "N/A" ]; then
      echo "⚠️ Skipping [$key] - remote version not found."
      continue
    fi

    case "$key" in
      "argo/argo-workflows")
        echo "-> Updating [argo-workflows] to version $target_ver..."
        pull_and_extract_chart "argo/argo-workflows" "argo-workflows" "$target_ver"
        ;;
      "nvidia/gpu-operator")
        echo "-> Updating [gpu-operator] to version $target_ver..."
        pull_and_extract_chart "nvidia/gpu-operator" "gpu-operator" "$target_ver"
        ;;
      "community-charts/mlflow")
        echo "-> Updating [mlflow] to version $target_ver..."
        pull_and_extract_chart "community-charts/mlflow" "mlflow" "$target_ver"
        ;;
      "helmforge/keycloak")
        echo "-> Updating [keycloak] to version $target_ver..."
        pull_and_extract_chart "helmforge/keycloak" "keycloak" "$target_ver"
        ;;
      "kyverno/kyverno")
        echo "-> Updating [kyverno] to version $target_ver..."
        pull_and_extract_chart "kyverno/kyverno" "kyverno" "$target_ver"
        ;;
      "victoria-metrics/victoria-metrics-k8s-stack")
        echo "-> Updating [victoria-metrics-k8s-stack] to version $target_ver..."
        pull_and_extract_chart "victoria-metrics/victoria-metrics-k8s-stack" "victoria-metrics" "$target_ver"
        ;;
      "victoria-metrics/victoria-logs-cluster")
        echo "-> Updating [victoria-logs-cluster] to version $target_ver..."
        pull_and_extract_chart "victoria-metrics/victoria-logs-cluster" "victoria-logs" "$target_ver"
        ;;
      "vector/vector")
        echo "-> Updating [vector] to version $target_ver..."
        pull_and_extract_chart "vector/vector" "vector" "$target_ver"
        ;;
      "oauth2-proxy/oauth2-proxy")
        echo "-> Updating [oauth2-proxy] to version $target_ver..."
        pull_and_extract_chart "oauth2-proxy/oauth2-proxy" "oauth2-proxy" "$target_ver"
        ;;
      "kgateway")
        echo "-> Updating [kgateway] OCI charts to version $target_ver..."
        # OCI requires special manual multi-pull handling
        rm -rf "${SCRIPT_DIR}/kgateway/charts"
        mkdir -p "${SCRIPT_DIR}/kgateway/charts"
        helm pull oci://cr.kgateway.dev/kgateway-dev/charts/kgateway --version "$target_ver" --untar --destination "${SCRIPT_DIR}/kgateway/charts" >/dev/null
        helm pull oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds --version "$target_ver" --untar --destination "${SCRIPT_DIR}/kgateway/charts" >/dev/null
        ;;
      "nvidia-dra-driver")
        echo "-> Updating [nvidia-dra-driver] OCI chart to version $target_ver..."
        pull_and_extract_chart "oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu" "nvidia-dra-driver" "$target_ver"
        ;;
      "open-telemetry/opentelemetry-collector")
        echo "-> Updating [opentelemetry-collector] to version $target_ver..."
        pull_and_extract_chart "open-telemetry/opentelemetry-collector" "opentelemetry-collector" "$target_ver"
        ;;
      "istio/base")
        echo "-> Updating [istio-base] to version $target_ver..."
        pull_and_extract_chart "istio/base" "istio/charts/base" "$target_ver"
        ;;
      "istio/istiod")
        echo "-> Updating [istio-istiod] to version $target_ver..."
        pull_and_extract_chart "istio/istiod" "istio/charts/istiod" "$target_ver"
        ;;
      "istio/cni")
        echo "-> Updating [istio-cni] to version $target_ver..."
        pull_and_extract_chart "istio/cni" "istio/charts/cni" "$target_ver"
        ;;
      "istio/ztunnel")
        echo "-> Updating [istio-ztunnel] to version $target_ver..."
        pull_and_extract_chart "istio/ztunnel" "istio/charts/ztunnel" "$target_ver"
        ;;
      "istio/gateway")
        echo "-> Updating [istio-gateway] to version $target_ver..."
        pull_and_extract_chart "istio/gateway" "istio/charts/gateway" "$target_ver"
        ;;
      "gateway-api")
        echo "-> Updating [gateway-api] CRDs to version $target_ver..."
        mkdir -p "${GITOPS_DIR}/bootstrap/static-crds"
        echo "# Source: https://github.com/kubernetes-sigs/gateway-api/releases/download/${target_ver}/experimental-install.yaml" > "${GITOPS_DIR}/bootstrap/static-crds/gateway-api-crds.yaml"
        curl -sL "https://github.com/kubernetes-sigs/gateway-api/releases/download/${target_ver}/experimental-install.yaml" >> "${GITOPS_DIR}/bootstrap/static-crds/gateway-api-crds.yaml"
        ;;
      "metrics-server")
        echo "-> Updating [metrics-server] manifest to version $target_ver..."
        mkdir -p "${local_path}"
        echo "# Source: https://github.com/kubernetes-sigs/metrics-server/releases/download/${target_ver}/components.yaml" > "${local_path}/metrics-server.yaml"
        curl -sL "https://github.com/kubernetes-sigs/metrics-server/releases/download/${target_ver}/components.yaml" >> "${local_path}/metrics-server.yaml"
        ;;
    esac
  done
  echo "============================================================="
  echo "       All target Helm charts updated successfully!"
  echo "============================================================="
else
  echo "Update canceled. Exiting."
fi
