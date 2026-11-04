#!/bin/bash
# DiskActiveProbe 실행. 관리자 권한 필요. 결과: results/<시각>-<명령>/
#   sudo ./run.sh check              1단계: 추적 자리·이벤트 모양·디스크 대응·드라이버 통계 대조 (약 30초)
#   sudo ./run.sh load [SD 경로]      부하 단계 + 1초 표본 (약 2분 30초, SD 카드 경로를 주면 약 3분 30초)
#   sudo ./run.sh live               1초마다 디스크별 활성 %·평균 동시 요청 (Ctrl-C로 끝)
#   sudo ./run.sh record [분]         실사용 기록 (기본 10분, Ctrl-C로 일찍 끝낼 수 있음)
#   sudo ./run.sh coexist [BCDE]     3단계: 다른 추적 도구(fs_usage·xctrace)와 함께·강제 종료 뒤·비켜주기 (약 3분, 글자로 시험을 고름)
#   sudo ./run.sh status             지금 커널 추적을 누가 쓰는지 (읽기만)
#   sudo ./run.sh reset              비정상 종료로 남은 추적 정리 (다른 도구가 쓰는 중이면 손대지 않음)
set -euo pipefail
cd "$(dirname "$0")"

CMD="${1:-}"
case "$CMD" in
  check | load | live | record | coexist | status | reset) ;;
  *)
    sed -n '2,9p' "$0"
    exit 2
    ;;
esac
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

if [[ "$CMD" == status || "$CMD" == reset ]]; then
  "$P" "$CMD"
  exit $?
fi

need_gb=2
if [[ "$CMD" == load ]]; then need_gb=4; fi
avail_kb=$(df -k . | awk 'NR==2 {print $4}')
if (( avail_kb < need_gb * 1024 * 1024 )); then
  echo "여유 공간이 ${need_gb} GB보다 작아서 멈춥니다"
  exit 1
fi

EXTRA=()
if [[ "$CMD" == load && -n "${2:-}" ]]; then
  SD="${2%/}"
  if [[ ! -d "$SD" ]]; then
    echo "SD 카드 경로가 없음: $SD"
    exit 1
  fi
  EXTRA+=("$SD")
fi
if [[ "$CMD" == coexist ]]; then
  SEL="${2:-BCDE}"
  if ! [[ "$SEL" =~ ^[BCDE]+$ ]]; then
    echo "시험 글자는 B·C·D·E 중에서: $SEL"
    exit 1
  fi
fi
if [[ "$CMD" == record ]]; then
  MIN="${2:-10}"
  if ! [[ "$MIN" =~ ^[0-9]+$ ]] || (( MIN < 1 )); then
    echo "분은 1 이상의 정수: $MIN"
    exit 1
  fi
  EXTRA+=("$MIN")
fi

OUT="results/$(date +%Y%m%d-%H%M%S)-$CMD"
as_user mkdir -p "$OUT"
set +e
if [[ "$CMD" == coexist ]]; then
  bash ./coexist.sh "$P" "$OUT" "$SEL"
else
  # macOS의 bash 3.2는 빈 배열을 set -u에서 못 펼쳐서 ${A[@]+...} 꼴로 쓴다
  "$P" "$CMD" "$OUT" ${EXTRA[@]+"${EXTRA[@]}"}
fi
rc=$?
set -e
if [[ -n "$USER_NAME" ]]; then chown -R "$USER_NAME" "$OUT"; fi
if (( rc == 70 || rc >= 128 )); then
  echo "▶ 비정상 종료 (코드 $rc). 추적이 남았는지: sudo ./run.sh status · 정리: sudo ./run.sh reset"
fi
echo "▶ 결과: Diagnostics/DiskActiveProbe/$OUT"
exit "$rc"
