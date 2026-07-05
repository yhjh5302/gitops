#!/usr/bin/env bash

set -uo pipefail

# 스크립트 위치 기준 설정
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "${SCRIPT_DIR}")"
KUBEADM_DIR="${SCRIPT_DIR}"
COMMON_DIR="${INFRA_DIR}/common"
KIND_DIR="${INFRA_DIR}/kind"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}        Kubernetes 클러스터 대화형 구축 오케스트레이터        ${NC}"
echo -e "${BLUE}=============================================================${NC}"

# config.sh 환경변수 파일 로드
if [ -f "${KUBEADM_DIR}/config.sh" ]; then
  source "${KUBEADM_DIR}/config.sh"
fi

# hosts.map에서 특정 키(호스트네임)의 IP를 긁어오는 헬퍼 함수
get_ip_from_map() {
  local target_host="$1"
  local map_file="${KUBEADM_DIR}/hosts.map"
  if [ -f "$map_file" ]; then
    grep -E "^[0-9.]+[[:space:]]+.*${target_host}" "$map_file" 2>/dev/null | awk '{print $1}' | head -n 1 || \
    echo ""
  else
    echo ""
  fi
}

# kubeadm, kubectl, kubelet 버전 호환성 검사 헬퍼 함수
check_version_compatibility() {
  echo -e "\n${BLUE}[안내] Kubernetes CLI 및 데몬 버전 호환성을 검증합니다...${NC}"
  
  # 1. 버전 문자열 추출
  local kubeadm_raw=""
  kubeadm_raw=$(kubeadm version -o short 2>/dev/null || kubeadm version 2>/dev/null || echo "")
  local kubeadm_ver=""
  kubeadm_ver=$(echo "${kubeadm_raw}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "")
  
  local kubectl_raw=""
  kubectl_raw=$(kubectl version --client 2>/dev/null || echo "")
  local kubectl_ver=""
  kubectl_ver=$(echo "${kubectl_raw}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "")
  
  local kubelet_raw=""
  kubelet_raw=$(kubelet --version 2>/dev/null || echo "")
  local kubelet_ver=""
  kubelet_ver=$(echo "${kubelet_raw}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "")

  echo " -> 감지된 버전 정보:"
  echo "    * kubeadm: v${kubeadm_ver:-미설치}"
  echo "    * kubectl: v${kubectl_ver:-미설치}"
  echo "    * kubelet: v${kubelet_ver:-미설치}"

  if [ -z "${kubeadm_ver}" ] || [ -z "${kubectl_ver}" ] || [ -z "${kubelet_ver}" ]; then
    echo -e "${RED}[오류] 일부 쿠버네티스 CLI 도구(kubeadm/kubectl/kubelet)가 미설치 상태이거나 버전을 읽을 수 없습니다.${NC}" >&2
    return 1
  fi

  # 2. 마이너 버전 추출 (예: "1.35.6" -> "1.35")
  local kubeadm_minor=""
  kubeadm_minor=$(echo "${kubeadm_ver}" | cut -d. -f1,2)
  local kubectl_minor=""
  kubectl_minor=$(echo "${kubectl_ver}" | cut -d. -f1,2)
  local kubelet_minor=""
  kubelet_minor=$(echo "${kubelet_ver}" | cut -d. -f1,2)

  # 마이너 버전 숫자 비교를 위해 '.' 제거 (예: "1.35" -> "135")
  local adm_num=${kubeadm_minor//./}
  local let_num=${kubelet_minor//./}
  local ctl_num=${kubectl_minor//./}

  # 3. 호환성 검증
  # 규칙 A: kubelet 버전은 제어 평면을 초기화하는 kubeadm 버전보다 낮거나 같아야 함
  if [ "${let_num}" -gt "${adm_num}" ]; then
    echo -e "${RED}[오류] kubelet 버전(v${kubelet_ver})이 kubeadm 버전(v${kubeadm_ver})보다 최신입니다.${NC}" >&2
    echo -e "${RED}쿠버네티스 정책상 노드 kubelet 버전은 마스터 제어 평면(kubeadm) 버전보다 높을 수 없습니다.${NC}" >&2
    return 1
  fi
  
  # 규칙 B: kubectl 버전은 kubeadm과 마이너 버전 차이가 +/- 1 이내여야 함
  local diff_ctl=$(( ctl_num - adm_num ))
  if [ "${diff_ctl#-}" -gt 1 ]; then
    echo -e "${RED}[오류] kubectl 버전(v${kubectl_ver})과 kubeadm 버전(v${kubeadm_ver}) 차이가 마이너 기준 2 이상입니다.${NC}" >&2
    echo -e "${RED}쿠버네티스 공식 지원 정책(Skew Policy)상 kubectl은 제어 평면과 +/- 1 마이너 버전 범위 안에서만 호환됩니다.${NC}" >&2
    return 1
  fi

  if [ "${adm_num}" -ne "${let_num}" ] || [ "${adm_num}" -ne "${ctl_num}" ]; then
    echo -e "${YELLOW}[경고] 버전 불일치가 감지되었습니다 (허용되는 스큐 범위 내).${NC}"
    echo -e "${YELLOW} -> 가능한 한 마이너 릴리스 버전을 일치시키는 것을 적극 권장합니다.${NC}"
  else
    echo -e "${GREEN}✓ 버전 호환성 검증 성공: 모든 도구가 동일한 마이너 릴리스(v${kubeadm_minor})를 사용하는 중입니다.${NC}"
  fi

  return 0
}

confirm_and_run() {
  local step_name="$1"
  shift
  local cmd=("$@")
  
  echo -e "\n${BLUE}[대기] 단계: ${step_name}${NC}"
  read -p "실행하시겠습니까? (y/N): " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Executing: ${cmd[*]}${NC}"
    "${cmd[@]}"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✓ 성공: ${step_name}${NC}"
    else
      echo -e "${RED}✗ 실패: ${step_name}${NC}"
      exit 1
    fi
  else
    echo -e "안내: 단계를 건너뜁니다."
  fi
}

master_menu() {
  while true; do
    echo -e "\n${BLUE}--- [Master Node Setup Menu] ---${NC}"
    echo "1) hosts.map 동기화 (/etc/hosts 설정)"
    echo "2) OS 튜닝 및 Swap 비활성화 (prepare-node.sh)"
    echo "3) Containerd 런타임 설치 및 cgroup/Limit 튜닝 (install-containerd.sh)"
    echo "4) Kubernetes 도구 설치 (kubeadm, kubelet, kubectl)"
    echo "5) 사설 레지스트리로 시스템 이미지 동기화 (push-k8s-images.sh)"
    echo "6) Control Plane 초기화 (kubeadm init)"
    echo "7) 메인 메뉴로 돌아가기"
    read -p "원하는 단계의 번호를 입력하세요: " sub_choice
    
    case $sub_choice in
      1)
        confirm_and_run "hosts.map 동기화" sudo bash "${KUBEADM_DIR}/setup-hosts.sh"
        ;;
      2)
        confirm_and_run "OS 및 Swap 설정" sudo bash "${KUBEADM_DIR}/prepare-node.sh"
        ;;
      3)
        local default_doc_data="${DOCKER_DATA_ROOT:-/var/lib/docker}"
        local default_doc_exec="${DOCKER_EXEC_ROOT:-/var/run/docker}"
        local default_cont_root="${CONTAINERD_ROOT:-/var/lib/containerd}"
        local default_cont_state="${CONTAINERD_STATE:-/run/containerd}"

        echo "Containerd 경로 변경 옵션 (엔터를 누르면 기본 경로가 설정됩니다):"
        read -p "Docker Data Root (기본 ${default_doc_data}): " doc_data
        read -p "Docker Exec Root (기본 ${default_doc_exec}): " doc_exec
        read -p "Containerd Root (기본 ${default_cont_root}): " cont_root
        read -p "Containerd State (기본 ${default_cont_state}): " cont_state
        
        doc_data="${doc_data:-$default_doc_data}"
        doc_exec="${doc_exec:-$default_doc_exec}"
        cont_root="${cont_root:-$default_cont_root}"
        cont_state="${cont_state:-$default_cont_state}"
        
        confirm_and_run "Containerd 설치" sudo bash "${KUBEADM_DIR}/install-containerd.sh" "$doc_data" "$doc_exec" "$cont_root" "$cont_state"
        ;;
      4)
        local default_k8s_ver="${KUBERNETES_VERSION:-v1.36}"
        confirm_and_run "Kubernetes 도구 설치 (${default_k8s_ver})" sudo bash "${KUBEADM_DIR}/install-k8s-tools.sh" "${default_k8s_ver}"
        ;;
      5)
        confirm_and_run "사설 레지스트리 이미지 동기화" bash "${KUBEADM_DIR}/push-k8s-images.sh"
        ;;
      6)
        # 0순위: 도구 버전 호환성 체크
        if ! check_version_compatibility; then
          echo -e "${RED}호환성 검사 실패: 도구 버전을 맞춘 후 다시 진행해주세요.${NC}"
          continue
        fi

        # 1순위: hosts.map에서 cluster-endpoint 도메인으로 IP 검색 (kubeadm init용)
        local parsed_ip=$(get_ip_from_map "cluster-endpoint")
        
        # 2순위: 현재 머신의 호스트네임으로 hosts.map에서 IP 검색 (fallback 1)
        if [ -z "$parsed_ip" ]; then
          local current_hostname=$(hostname)
          parsed_ip=$(get_ip_from_map "$current_hostname")
        fi
        
        # 3순위: 시스템 네트워크 카드의 실제 첫 번째 IP 자동 감지 (fallback 2)
        if [ -z "$parsed_ip" ]; then
          parsed_ip=$(hostname -I | awk '{print $1}')
        fi
        local pod_cidr="${POD_NETWORK_CIDR:-10.233.0.0/16}"
        local service_cidr="${SERVICE_CIDR:-10.234.0.0/16}"
        local control_plane_endpoint="${CONTROL_PLANE_ENDPOINT:-cluster-endpoint:6443}"
        local image_repository="${IMAGE_REPOSITORY:-registry.k8s.io}"
        local kubernetes_version="${KUBERNETES_VERSION:-v1.35.6}"

        read -p "kubeadm init에 사용할 마스터 노드 IP를 입력하세요 (자동감지: ${parsed_ip}): " master_ip
        master_ip="${master_ip:-$parsed_ip}"
        
        if [ -z "$master_ip" ]; then
          echo -e "${RED}오류: 마스터 노드 IP를 지정해야 합니다.${NC}"
          continue
        fi

        read -p "kubeadm init에 사용할 Pod Network CIDR을 입력하세요 (기본값: ${pod_cidr}): " input_pod_cidr
        pod_cidr="${input_pod_cidr:-$pod_cidr}"

        read -p "kubeadm init에 사용할 Service CIDR을 입력하세요 (기본값: ${service_cidr}): " input_service_cidr
        service_cidr="${input_service_cidr:-$service_cidr}"

        # -v 로그 레벨 옵션 구성
        local v_flag=""
        local default_v="${KUBEADM_VERBOSITY:-}"
        if [ -n "$default_v" ]; then
          v_flag=" -v ${default_v}"
        fi
        
        echo -e "${BLUE}[안내] 마스터 노드 초기화를 진행합니다.${NC}"
        
        read -p "실행하시겠습니까? (y/N): " init_choice
        if [[ "$init_choice" =~ ^[Yy]$ ]]; then
          # 임시 kubeadm-config.yaml 파일 생성
          local config_file="kubeadm-config.yaml"
          local template_file="${SCRIPT_DIR}/kubeadm-config.yaml.template"

          if [ ! -f "${template_file}" ]; then
            echo -e "${RED}오류: 설정 템플릿 파일(${template_file})을 찾을 수 없습니다.${NC}" >&2
            exit 1
          fi

          sed -e "s|{master_ip}|${master_ip}|g" \
              -e "s|{kubernetes_version}|${kubernetes_version}|g" \
              -e "s|{control_plane_endpoint}|${control_plane_endpoint}|g" \
              -e "s|{image_repository}|${image_repository}|g" \
              -e "s|{pod_cidr}|${pod_cidr}|g" \
              -e "s|{service_cidr}|${service_cidr}|g" \
              "${template_file}" > "${config_file}"

          echo -e "${BLUE}생성된 kubeadm-config.yaml 파일을 사용하여 초기화를 진행합니다...${NC}"
          sudo kubeadm init --config "${config_file}" ${v_flag}
          local init_status=$?
          rm -f "${config_file}"
          
          if [ ${init_status} -eq 0 ]; then
            # 실제 실행한 일반 사용자 감지 및 해당 홈 디렉토리에 Kubeconfig 복사
            local target_user="${SUDO_USER:-$USER}"
            local target_home
            if [ -n "${SUDO_USER:-}" ]; then
              target_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
            else
              target_home="$HOME"
            fi
            
            echo -e "${BLUE}Kubeconfig 설정을 ${target_home}/.kube/config 에 복사합니다...${NC}"
            mkdir -p "${target_home}/.kube"
            sudo cp -f /etc/kubernetes/admin.conf "${target_home}/.kube/config"
            
            # 소유주를 실제 일반 사용자로 지정
            local target_uid=$(getent passwd "$target_user" | cut -d: -f3)
            local target_gid=$(getent passwd "$target_user" | cut -d: -f4)
            sudo chown "${target_uid}:${target_gid}" "${target_home}/.kube/config"

            # 일반 사용자의 .kube/config 파일을 가리키도록 KUBECONFIG 환경변수를 강제 고정하여 복사본 유효성 보장
            export KUBECONFIG="${target_home}/.kube/config"

            # API 서버가 실제로 응답을 시작할 때까지 대기
            echo " -> API 서버가 응답할 때까지 대기 중 (최대 60초)..."
            local api_ready=false
            local err_msg=""
            for i in {1..60}; do
              err_msg=$(kubectl get nodes --request-timeout='2s' 2>&1)
              if [ $? -eq 0 ]; then
                api_ready=true
                break
              fi
              echo "    [대기 ${i}/60] API 서버 연결 시도 중... (이유: ${err_msg})"
              sleep 1
            done

            if [ "$api_ready" = true ]; then
              if [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -eq 1 ]; then
                echo " -> 단일 노드 클러스터 감지: 마스터 노드 Taint를 제거하여 워크로드 스케줄링을 허용합니다."
                kubectl taint nodes --all node-role.kubernetes.io/control-plane- &>/dev/null || true
                kubectl taint nodes --all node-role.kubernetes.io/master- &>/dev/null || true
              fi
            else
              echo -e "${YELLOW} -> [경고] API 서버가 제한 시간 내에 응답하지 않아 Taint 해제를 건너뜁니다.${NC}"
            fi
            
            # Kubelet CSR 승인 루프 (15초 선대기 후 15초간 모니터링하며 100% 승인 보장)
            echo " -> Kubelet 데몬이 초기 CSR을 발행하도록 15초간 대기합니다..."
            sleep 15
            echo " -> Kubelet 인증서(Client 및 Serving) 승인을 대기합니다 (최대 15초)..."
            for i in {1..15}; do
              # Pending 상태인 CSR 검출 및 즉시 승인
              local pending_csrs=""
              pending_csrs=$(kubectl get csr 2>/dev/null | grep -i 'Pending' | awk '{print $1}' || echo '')
              if [ -n "${pending_csrs}" ]; then
                echo "    * 대기 중인 CSR 발견 및 승인 진행: ${pending_csrs}"
                echo "${pending_csrs}" | xargs -r kubectl certificate approve || true
              fi

              # serving 인증서가 등록되었고 더 이상 Pending이 없으면 조기 종료
              if kubectl get csr 2>/dev/null | grep -q "kubernetes.io/kubelet-serving"; then
                if ! kubectl get csr 2>/dev/null | grep -i 'Pending' &>/dev/null; then
                  echo " -> ✓ 모든 Kubelet 인증서(Client/Serving) 자동 승인 완료."
                  break
                fi
              fi
              sleep 1
            done

            echo -e "${GREEN}✓ 마스터 노드 초기화 및 Kubeconfig 적용 완료!${NC}"
          else
            echo -e "${RED}✗ 실패: kubeadm init 실행 중 치명적인 오류가 발생했습니다.${NC}"
            echo -e "${RED}사설 레지스트리의 이미지 보유 여부와 로그인(Public 권한 설정 등) 상태를 다시 확인해 주세요.${NC}"
          fi
        else
          echo "초기화를 취소했습니다."
        fi
        ;;
      7)
        break
        ;;
      *)
        echo -e "${RED}잘못된 번호입니다.${NC}"
        ;;
    esac
  done
}

worker_menu() {
  while true; do
    echo -e "\n${BLUE}--- [Worker Node Setup Menu] ---${NC}"
    echo "1) hosts.map 동기화 (/etc/hosts 설정)"
    echo "2) OS 튜닝 및 Swap 비활성화 (prepare-node.sh)"
    echo "3) Containerd 런타임 설치 및 cgroup/Limit 튜닝 (install-containerd.sh)"
    echo "4) Kubernetes 도구 설치 (install-k8s-tools.sh)"
    echo "5) NVIDIA GPU Open 커널 드라이버 설치 (install-nvidia.sh)"
    echo "6) 마스터 클러스터 조인 (kubeadm join)"
    echo "7) 메인 메뉴로 돌아가기"
    read -p "원하는 단계의 번호를 입력하세요: " sub_choice
    
    case $sub_choice in
      1)
        confirm_and_run "hosts.map 동기화" sudo bash "${KUBEADM_DIR}/setup-hosts.sh"
        ;;
      2)
        confirm_and_run "OS 및 Swap 설정" sudo bash "${KUBEADM_DIR}/prepare-node.sh"
        ;;
      3)
        local default_doc_data="${DOCKER_DATA_ROOT:-/var/lib/docker}"
        local default_doc_exec="${DOCKER_EXEC_ROOT:-/var/run/docker}"
        local default_cont_root="${CONTAINERD_ROOT:-/var/lib/containerd}"
        local default_cont_state="${CONTAINERD_STATE:-/run/containerd}"

        echo "Containerd 경로 변경 옵션 (엔터를 누르면 기본 경로가 설정됩니다):"
        read -p "Docker Data Root (기본 ${default_doc_data}): " doc_data
        read -p "Docker Exec Root (기본 ${default_doc_exec}): " doc_exec
        read -p "Containerd Root (기본 ${default_cont_root}): " cont_root
        read -p "Containerd State (기본 ${default_cont_state}): " cont_state
        
        doc_data="${doc_data:-$default_doc_data}"
        doc_exec="${doc_exec:-$default_doc_exec}"
        cont_root="${cont_root:-$default_cont_root}"
        cont_state="${cont_state:-$default_cont_state}"
        
        confirm_and_run "Containerd 설치" sudo bash "${KUBEADM_DIR}/install-containerd.sh" "$doc_data" "$doc_exec" "$cont_root" "$cont_state"
        ;;
      4)
        local default_k8s_ver="${KUBERNETES_VERSION:-v1.36}"
        confirm_and_run "Kubernetes 도구 설치 (${default_k8s_ver})" sudo bash "${KUBEADM_DIR}/install-k8s-tools.sh" "${default_k8s_ver}"
        ;;
      5)
        local default_nv_ver="${NVIDIA_DRIVER_VERSION:-580}"
        read -p "설치할 NVIDIA 드라이버 버전을 입력하세요 (기본값: ${default_nv_ver}): " nv_ver
        nv_ver="${nv_ver:-$default_nv_ver}"
        confirm_and_run "NVIDIA GPU 드라이버 설치" sudo bash "${KUBEADM_DIR}/install-nvidia.sh" "$nv_ver"
        ;;
      6)
        echo -e "${BLUE}[대기] 마스터 노드에서 생성된 'kubeadm join' 명령 전체를 복사하여 입력해 주세요:${NC}"
        read -p "명령어 입력: " join_cmd
        if [ -n "$join_cmd" ]; then
          # -v 로그 레벨 옵션 구성
          local default_v="${KUBEADM_VERBOSITY:-}"
          if [ -n "$default_v" ] && [[ ! "$join_cmd" =~ -v[[:space:]]+[0-9]+ ]] && [[ ! "$join_cmd" =~ --v=[0-9]+ ]]; then
            join_cmd="${join_cmd} -v ${default_v}"
          fi
          echo -e "${GREEN}Executing: sudo ${join_cmd}${NC}"
          eval "sudo ${join_cmd}"
          if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ 성공: 클러스터 조인 완료!${NC}"
          else
            echo -e "${RED}✗ 실패: 클러스터 조인 실패${NC}"
          fi
        else
          echo "입력된 명령어가 없어 건너뜁니다."
        fi
        ;;
      7)
        break
        ;;
      *)
        echo -e "${RED}잘못된 번호입니다.${NC}"
        ;;
    esac
  done
}

kind_menu() {
  while true; do
    echo -e "\n${BLUE}--- [Kind Local Cluster Setup Menu] ---${NC}"
    echo "1) Kind 로컬 클러스터 생성 (create-cluster.sh)"
    echo "2) 메인 메뉴로 돌아가기"
    read -p "원하는 단계의 번호를 입력하세요: " sub_choice
    
    case $sub_choice in
      1)
        confirm_and_run "Kind 클러스터 생성" bash "${KIND_DIR}/create-cluster.sh"
        ;;
      2)
        break
        ;;
      *)
        echo -e "${RED}잘못된 번호입니다.${NC}"
        ;;
    esac
  done
}

kubeadm_role_menu() {
  while true; do
    echo -e "\n${BLUE}--- [Kubeadm Setup: Node Role Selection] ---${NC}"
    echo "1) 마스터 노드 (Control Plane) 구성 진행"
    echo "2) 워커 노드 (GPU Worker VM) 구성 진행"
    echo "3) 메인 메뉴로 돌아가기"
    read -p "이 노드의 역할을 선택하세요: " role_choice
    
    case $role_choice in
      1)
        master_menu
        ;;
      2)
        worker_menu
        ;;
      3)
        break
        ;;
      *)
        echo -e "${RED}잘못된 입력입니다. 1, 2, 3 중 하나를 입력해 주세요.${NC}"
        ;;
    esac
  done
}

# 메인 메뉴 루프
while true; do
  echo -e "\n${BLUE}--- [Main Menu: Kubernetes Setup Orchestrator] ---${NC}"
  echo "1) Kubeadm 기반 멀티 노드 클러스터 구축 (물리 서버 / VM)"
  echo "2) Kind 기반 로컬 단일 노드 클러스터 구축 (Docker 컨테이너)"
  echo "3) 종료"
  read -p "구축할 클러스터 방식을 선택하세요 (1-3): " main_choice
  
  case $main_choice in
    1)
      kubeadm_role_menu
      ;;
    2)
      kind_menu
      ;;
    3)
      echo -e "${GREEN}오케스트레이터를 종료합니다. 구축을 이어서 진행하려면 다시 실행해 주세요.${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}잘못된 입력입니다. 1, 2, 3 중 하나를 입력해 주세요.${NC}"
      ;;
  esac
done
