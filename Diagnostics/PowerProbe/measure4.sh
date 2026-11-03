#!/bin/bash
# PowerProbe 4차 (macOS 27.2): ANE에 실제로 일을 시켰을 때 ANE 값이 아직 나오는지 확인해요.
#  - powermetrics(관리자 권한)의 ANE 전력
#  - 관리자 권한 없이 읽는 IOReport의 ANE 전원 상태(ANE0 ACT)와 ANE 메모리 트래픽 (MonitorTool이 쓰는 값)
#  - 대조: 가만히 / ANE 부하 / GPU 부하
#  - 마지막 40초는 ANE 부하를 다시 걸어 두니, 그동안 MonitorTool 패널의 ANE 칸을 봐 주세요.
# 3분쯤 걸려요. MonitorTool은 켜 둔 채로 실행해도 돼요.
# 사용법: 터미널에서 (앞에 sudo를 붙이지 마세요)
#   bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/PowerProbe/measure4.sh

set -u
cd "$(dirname "$0")" || exit 1

if [ "$(id -u)" -eq 0 ]; then
  echo "sudo 없이 실행해 주세요. powermetrics 단계만 스크립트가 따로 sudo로 실행해요."
  exit 1
fi

OUT=results-4
mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"

WARMUP=5      # 부하가 자리 잡을 때까지(초)
SAMPLE=12     # IOReport 기록 시간(초)
PM_COUNT=6    # powermetrics 표본 수(1초 간격)
WATCH=40      # 마지막에 패널을 볼 시간(초)

BIN_DIR="$(mktemp -d)"
LOAD="$BIN_DIR/ane_load"
PROBE="$BIN_DIR/ioreport_probe"
KEEPALIVE_PID=""

cleanup() {
  [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null
  for pid in $(jobs -p); do kill "$pid" 2>/dev/null; done
  rm -rf "$BIN_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "== 1/5 진단 도구 빌드 (1분쯤) =="
: > "$OUT/build.txt"
if ! swiftc -O ane_load.swift -o "$LOAD" >> "$OUT/build.txt" 2>&1 \
   || ! swiftc -O ioreport_probe.swift -o "$PROBE" >> "$OUT/build.txt" 2>&1; then
  echo "빌드 실패. $OUT/build.txt 내용:"; cat "$OUT/build.txt"; exit 1
fi

echo "== 2/5 ANE 부하 시험 실행 (3초) =="
if ! "$LOAD" 3 ane > "$OUT/load-test.txt" 2>&1; then
  echo "⚠️ ANE 부하를 걸지 못했어요. 내용:"; cat "$OUT/load-test.txt"
  echo "(이 결과도 Claude에게 그대로 알려 주세요)"; exit 1
fi
tail -n 1 "$OUT/load-test.txt"

echo "== 관리자 암호를 한 번 입력해 주세요 (powermetrics) =="
sudo -v || exit 1
( while true; do sudo -n true 2>/dev/null; sleep 30; done ) &
KEEPALIVE_PID=$!

{ sw_vers; sysctl -n machdep.cpu.brand_string; date; } > "$OUT/system.txt" 2>&1
pgrep -lx MonitorTool > "$OUT/monitortool-running.txt" 2>&1 || echo "MonitorTool 안 켜짐" > "$OUT/monitortool-running.txt"

# 한 단계: (부하) → IOReport ${SAMPLE}초(권한 없이) → powermetrics ${PM_COUNT}초
run_phase() {
  local label=$1 target=$2 load_pid=""
  if [ "$target" != none ]; then
    "$LOAD" $((WARMUP + SAMPLE + PM_COUNT + 6)) "$target" > "$OUT/load-$label.txt" 2>&1 &
    load_pid=$!
    sleep "$WARMUP"
  fi
  "$PROBE" sample "$SAMPLE" "$OUT" "$label" > "$OUT/ioreport-$label.txt" 2> "$OUT/ioreport-$label.log"
  sudo -n powermetrics --samplers cpu_power,gpu_power,ane_power -i 1000 -n "$PM_COUNT" \
    > "$OUT/pm-$label.txt" 2>&1
  [ -n "$load_pid" ] && wait "$load_pid"
  echo "   $label 기록함 $( [ -n "$load_pid" ] && tail -n 1 "$OUT/load-$label.txt")"
}

echo "== 3/5 가만히 → ANE 부하 → GPU 부하 (단계마다 25초쯤) =="
run_phase idle none
run_phase ane ane
run_phase gpu gpu

echo "== 4/5 지금부터 ${WATCH}초 동안 ANE 부하를 걸어요 =="
echo "   ★ MonitorTool 패널을 열고 ANE 칸(사용 중/쉬는 중, 전력 W)과 GPU 칸을 봐 주세요."
echo "   ★ 가능하면 ANE 칸을 눌러 펼친 화면도 캡처해 주세요."
"$LOAD" "$WATCH" ane > "$OUT/load-watch.txt" 2>&1 &
watch_pid=$!
for ((left = WATCH; left > 0; left -= 10)); do echo "   남은 시간 ${left}초"; sleep 10; done
wait "$watch_pid"

echo "== 5/5 요약 =="
{
  echo "# PowerProbe 4차 요약"; cat "$OUT/system.txt"; echo "MonitorTool: $(cat "$OUT/monitortool-running.txt")"
  for label in idle ane gpu; do
    echo; echo "## $label"
    [ -f "$OUT/load-$label.txt" ] && echo "부하: $(tail -n 1 "$OUT/load-$label.txt")"
    echo "[powermetrics]"
    grep -E '^(CPU Power|GPU Power|ANE Power|GPU HW active residency)' "$OUT/pm-$label.txt" \
      | awk -F: '{k=$1; sub(/^[ \t]+/,"",$2); v[k]=v[k] " " $2} END {for (k in v) print "  " k ":" v[k]}' | sort
    echo "[IOReport, 권한 없이]"
    grep -E 'ANE|GPU Energy|Device Utilization' "$OUT/ioreport-$label.txt" | grep -v -E '^(구독|PMP)|/ Events /' | sed 's/^/  /'
  done
} > "$SUMMARY"
cat "$SUMMARY"
echo
echo "== 끝났어요. Claude에게 '4차 측정 끝났어'라고 알려 주세요 (패널 캡처가 있으면 같이) =="
