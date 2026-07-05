#!/usr/bin/env bash

set -euo pipefail

# root 권한 체크
if [ "$EUID" -ne 0 ]; then
  echo "오류: 이 스크립트는 root 권한(sudo)으로 실행해야 합니다."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP_FILE="${1:-$SCRIPT_DIR/hosts.map}"

MARKER_BEGIN="# BEGIN KUBERNETES HOST MAPPINGS"
MARKER_END="# END KUBERNETES HOST MAPPINGS"

echo "============================================================="
echo "/etc/hosts 호스트 파일 자동 설정 스크립트"
echo "Target Configuration File: ${MAP_FILE}"
echo "============================================================="

# hosts.map 파일이 없는 경우, 템플릿 복사 후 안내 및 종료
if [ ! -f "$MAP_FILE" ]; then
  if [ -f "$SCRIPT_DIR/hosts.map.example" ]; then
    cp "$SCRIPT_DIR/hosts.map.example" "$MAP_FILE"
    echo "안내: '${MAP_FILE}' 파일이 존재하지 않아 템플릿(hosts.map.example)으로부터 자동 복사하여 생성했습니다."
    echo "새로 생성된 '${MAP_FILE}' 파일을 열어 실제 서버 IP 정보를 기입한 뒤, 이 스크립트를 다시 실행해 주세요."
  else
    echo "오류: '${MAP_FILE}' 파일이 존재하지 않고, 백업 템플릿도 찾을 수 없습니다."
  fi
  exit 1
fi

# 1. 기존 마커 블록이 존재한다면 제거하여 이전 설정을 청소
if grep -qF "$MARKER_BEGIN" /etc/hosts; then
  echo "업데이트: 기존에 삽입된 Kubernetes 호스트 블록을 삭제합니다."
  sed -i "/$MARKER_BEGIN/,/$MARKER_END/d" /etc/hosts
fi

# 2. hosts.map 파싱하여 추가할 블록 생성
TEMP_BLOCK=""
echo "설정 파일을 파싱하여 삽입할 호스트 블록을 구성 중..."
while IFS= read -r line || [ -n "$line" ]; do
  # 주석(#) 제거 및 좌우 공백 트리밍
  clean_line=$(echo "$line" | sed 's/#.*//' | xargs)
  
  # 빈 줄 건너뛰기
  if [ -z "$clean_line" ]; then
    continue
  fi
  
  # 공백 기준으로 토큰 분리 (첫 번째 토큰=IP, 나머지 토큰들=호스트네임 리스트)
  read -r -a tokens <<< "$clean_line"
  
  if [ ${#tokens[@]} -lt 2 ]; then
    echo "경고: 올바르지 않은 설정 형식입니다 (건너뜀) -> $line"
    continue
  fi
  
  IP="${tokens[0]}"
  HOSTNAMES=("${tokens[@]:1}")
  
  # 하나의 문자열 라인으로 조합
  formatted_line="${IP}"
  for hostname in "${HOSTNAMES[@]}"; do
    formatted_line="${formatted_line}    ${hostname}"
  done
  
  TEMP_BLOCK="${TEMP_BLOCK}${formatted_line}\n"
done < "$MAP_FILE"

# 3. 마커 블록과 함께 /etc/hosts 파일 하단에 주입
if [ -n "$TEMP_BLOCK" ]; then
  # 파일의 마지막 라인이 완전히 비어있지 않은 경우에만 줄바꿈 추가
  if [ -n "$(tail -n1 /etc/hosts 2>/dev/null | xargs)" ]; then
    echo "" >> /etc/hosts
  fi
  
  {
    echo "$MARKER_BEGIN"
    echo -e -n "$TEMP_BLOCK"
    echo "$MARKER_END"
  } >> /etc/hosts
  echo "-> Kubernetes 호스트 블록이 /etc/hosts에 안전하게 동기화되었습니다."
else
  echo "안내: 등록할 호스트 설정 정보가 없습니다."
fi

echo "============================================================="
echo "/etc/hosts 갱신 완료!"
echo "============================================================="
cat /etc/hosts
