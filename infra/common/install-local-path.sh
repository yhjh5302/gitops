#!/usr/bin/env bash

# Rancher Local Path Provisioner 설치 스크립트 (Kubeadm 로컬 동적 스토리지 제공용)
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}        Rancher Local Path Provisioner 설치 스크립트          ${NC}"
echo -e "${BLUE}=============================================================${NC}"

echo -e "${GREEN}1단계: 공식 YAML 매니페스트 배포 (v0.0.36)${NC}"
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml

echo -e "\n${GREEN}2단계: local-path StorageClass를 기본값(Default)으로 설정${NC}"
# 다른 StorageClass가 기본값으로 선언되어 있을 수 있으므로 어노테이션 강제 주입
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo -e "\n${GREEN}3단계: Local Path Provisioner Pod 구동 대기${NC}"
echo " -> local-path-provisioner Pod가 실행(Running) 및 준비 완료될 때까지 대기합니다..."
kubectl wait --namespace local-path-storage --for=condition=Ready pod -l app=local-path-provisioner --timeout=3m

echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}Local Path Provisioner 설치 및 기본값 설정이 성공적으로 완료되었습니다!${NC}"
echo -e "${GREEN}=============================================================${NC}"
