#!/bin/bash
# DiskActiveProbe 실행. 관리자 권한 필요.
#   sudo ./run.sh check    1단계: 추적 자리·이벤트 모양·디스크 대응·드라이버 통계 대조 (약 30초)
#   sudo ./run.sh status   지금 커널 추적을 누가 쓰는지 (읽기만)
#   sudo ./run.sh reset    비정상 종료로 남은 추적 정리 (다른 도구가 쓰는 중이면 손대지 않음)
set -euo pipefail
cd "$(dirname "$0")"

CMD="${1:-}"
if [[ "$CMD" != check && "$CMD" != status && "$CMD" != reset ]]; then
  sed -n '2,5p' "$0"
  exit 2
fi
if [[ $EUID -ne 0 ]]; then
  echo "관리자 권한 필요: sudo ./run.sh $CMD"
  exit 1
fi

# 빌드와 결과 폴더는 sudo를 부른 사용자 권한으로 (결과 파일 소유자도 끝에 되돌림)
USER_NAME="${SUDO_USER:-}"
as_user() {
  if [[ -n "$USER_NAME" ]]; then sudo -u "$USER_NAME" -H "$@"; else "$@"; fi
}

P=build/diskactiveprobe
need_build=0
if [[ ! -x "$P" ]]; then
  need_build=1
elif [[ -n "$(find Sources run.sh -newer "$P")" ]]; then
  need_build=1
fi
if (( need_build )); then
  echo "▶ 빌드"
  as_user mkdir -p build
  as_user xcrun swiftc -O -swift-version 5 -o "$P" Sources/*.swift
fi

case "$CMD" in
  status | reset)
    "$P" "$CMD"
    ;;
  check)
    avail_kb=$(df -k . | awk 'NR==2 {print $4}')
    if (( avail_kb < 2 * 1024 * 1024 )); then
      echo "여유 공간이 2 GB보다 작아서 멈춥니다"
      exit 1
    fi
    OUT="results/$(date +%Y%m%d-%H%M%S)"
    as_user mkdir -p "$OUT"
    set +e
    "$P" check "$OUT"
    rc=$?
    set -e
    if [[ -n "$USER_NAME" ]]; then chown -R "$USER_NAME" "$OUT"; fi
    echo "▶ 결과: Diagnostics/DiskActiveProbe/$OUT"
    exit "$rc"
    ;;
esac
