#!/bin/bash
# DiskActiveProbe 실행. 관리자 권한 필요. 결과: results/<시각>-<명령>/
#   sudo ./run.sh check              1단계: 추적 자리·이벤트 모양·디스크 대응·드라이버 통계 대조 (약 30초)
#   sudo ./run.sh load [SD 경로]      부하 단계 + 1초 표본 (약 2분 30초, SD 카드 경로를 주면 약 3분 30초)
#   sudo ./run.sh live               1초마다 디스크별 활성 %·평균 동시 요청 (Ctrl-C로 끝)
#   sudo ./run.sh record [분]         실사용 기록 (기본 10분, Ctrl-C로 일찍 끝낼 수 있음)
#   sudo ./run.sh coexist [BCDE]     3단계: 다른 추적 도구(fs_usage·xctrace)와 함께·강제 종료 뒤·비켜주기 (약 3분, 글자로 시험을 고름)
#   sudo ./run.sh cost [방식] [초]     4단계: 비용 (시스템 콜·추적 없는 부하·읽는 방식별 가만히·무거운 부하·읽기 버퍼·비켜주기, 약 6분)
#                                    방식은 쉼표로 (예 cost w 60: w만, 가만히 60초)
#   sudo ./run.sh soak [분|시:분] [읽기] [깨어 있을 분]  4단계: 오래 켜 두기 (예 soak 09:00 w 120, 기본 720분·w·0, Ctrl-C로 끝)
#   sudo ./run.sh status             지금 커널 추적을 누가 쓰는지 (읽기만)
#   sudo ./run.sh reset              비정상 종료로 남은 추적 정리 (다른 도구가 쓰는 중이면 손대지 않음)
set -euo pipefail
cd "$(dirname "$0")"

CMD="${1:-}"
case "$CMD" in
  check | load | live | record | coexist | cost | soak | status | reset) ;;
  *)
    sed -n '2,12p' "$0"
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
if [[ "$CMD" == load || "$CMD" == cost ]]; then need_gb=4; fi
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
if [[ "$CMD" == cost ]]; then
  MODES="${2:-100,250,500,1000,w}"
  IDLE="${3:-20}"
  re_modes='^((w|[0-9]+),)*(w|[0-9]+)$'
  if ! [[ "$MODES" =~ $re_modes ]]; then
    echo "읽는 방식은 쉼표로 (ms 또는 w, 예 100,w): $MODES"
    exit 1
  fi
  if ! [[ "$IDLE" =~ ^[0-9]+$ ]] || (( IDLE < 5 )); then
    echo "가만히 초는 5 이상의 정수: $IDLE"
    exit 1
  fi
fi
AWAKE=0
if [[ "$CMD" == soak ]]; then
  UNTIL="${2:-720}"
  READ="${3:-w}"
  AWAKE="${4:-0}"
  re_clock='^([01]?[0-9]|2[0-3]):[0-5][0-9]$'
  if [[ "$UNTIL" =~ $re_clock ]]; then
    # 끝낼 시각: 오늘 그 시각, 이미 지났으면 내일
    now_s=$(date +%s)
    end_s=$(date -j -f "%H:%M:%S" "${UNTIL}:00" +%s)
    if (( end_s <= now_s )); then end_s=$((end_s + 86400)); fi
    MIN=$(( (end_s - now_s + 59) / 60 ))
  elif [[ "$UNTIL" =~ ^[0-9]+$ ]] && (( UNTIL >= 1 )); then
    MIN="$UNTIL"
  else
    echo "끝은 분(1 이상의 정수) 또는 시:분(예 09:00): $UNTIL"
    exit 1
  fi
  if ! [[ "$READ" == w || "$READ" =~ ^[0-9]+$ ]]; then
    echo "읽기는 ms(10~5000) 또는 w: $READ"
    exit 1
  fi
  if ! [[ "$AWAKE" =~ ^[0-9]+$ ]]; then
    echo "깨어 있을 분은 0 이상의 정수: $AWAKE"
    exit 1
  fi
  echo "▶ 오래 켜 두기: 약 ${MIN}분 ($(date -v+${MIN}M +%H:%M)쯤 끝) · 읽기 $READ · 처음 ${AWAKE}분은 스스로 잠들지 않게"
  EXTRA+=("$MIN" "$READ")
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
# 오래 켜 두기: 처음 AWAKE분은 caffeinate -i로 스스로 잠들지 않게 (화면은 꺼짐, 덮개를 닫으면 잠듦). 그 뒤에는 평소대로 잠든다
CAF=""
if [[ "$CMD" == soak ]] && (( AWAKE > 0 )); then
  caffeinate -i -t $((AWAKE * 60)) &
  CAF=$!
  echo "$(date +%H:%M:%S).000 [run] caffeinate -i ${AWAKE}분 (pid $CAF): 그동안 스스로 잠들지 않음" >> "$OUT/timeline.txt"
fi
set +e
if [[ "$CMD" == coexist ]]; then
  bash ./coexist.sh "$P" "$OUT" "$SEL"
elif [[ "$CMD" == cost ]]; then
  bash ./cost.sh "$P" "$OUT" "$MODES" "$IDLE"
else
  # macOS의 bash 3.2는 빈 배열을 set -u에서 못 펼쳐서 ${A[@]+...} 꼴로 쓴다
  "$P" "$CMD" "$OUT" ${EXTRA[@]+"${EXTRA[@]}"}
fi
rc=$?
set -e
if [[ -n "$CAF" ]]; then kill "$CAF" 2>/dev/null || true; fi
if [[ -n "$USER_NAME" ]]; then chown -R "$USER_NAME" "$OUT"; fi
if (( rc == 70 || rc >= 128 )); then
  echo "▶ 비정상 종료 (코드 $rc). 추적이 남았는지: sudo ./run.sh status · 정리: sudo ./run.sh reset"
fi
echo "▶ 결과: Diagnostics/DiskActiveProbe/$OUT"
exit "$rc"
