#!/bin/bash
# PowerProbe 3차: ANE에 일을 띄엄띄엄 줄 때 ANE 전원 상태(ACT) 비율이 일한 양에 비례하는지,
# CPU 번호와 E/P 묶음의 대응(IODeviceTree), powermetrics의 --show-extra-power-info를 확인해요.
# 3분쯤 걸려요.
# 사용법: 터미널에서 (앞에 sudo를 붙이지 마세요)
#   bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/PowerProbe/measure3.sh

set -u
cd "$(dirname "$0")" || exit 1

if [ "$(id -u)" -eq 0 ]; then
  echo "sudo 없이 실행해 주세요. 관리자 권한이 필요한 마지막 단계만 스크립트가 따로 sudo로 실행해요."
  exit 1
fi

OUT=results-3
mkdir -p "$OUT"

WARMUP=5        # 부하가 자리 잡을 때까지 기다리는 시간(초)
SAMPLE=12       # 단계마다 기록하는 시간(초)
RATES="0 48 24 12 4"   # 초당 ANE 요청 수 (0은 제한 없이 최대한 빠르게)

BIN_DIR="$(mktemp -d)"
LOAD="$BIN_DIR/ane_load"
PROBE="$BIN_DIR/ioreport_probe"

cleanup() {
  for pid in $(jobs -p); do
    kill "$pid" 2>/dev/null
  done
  rm -rf "$BIN_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "== 1/4 진단 도구 빌드 (1분쯤) =="
: > "$OUT/build.txt"
if ! swiftc -O ane_load.swift -o "$LOAD" >> "$OUT/build.txt" 2>&1 \
   || ! swiftc -O ioreport_probe.swift -o "$PROBE" >> "$OUT/build.txt" 2>&1; then
  echo "빌드 실패. $OUT/build.txt 내용:"
  cat "$OUT/build.txt"
  exit 1
fi

echo "== 관리자 암호를 한 번 입력해 주세요 (마지막 단계에서 powermetrics를 써요) =="
sudo -v || exit 1
# 측정이 길어도 암호를 다시 묻지 않도록 sudo 인증 시간을 계속 연장해요.
( while true; do sudo -n true 2>/dev/null; sleep 30; done ) &

sw_vers > "$OUT/system.txt" 2>&1

echo "== 2/4 CPU 번호와 E/P 묶음 (IODeviceTree) =="
"$PROBE" cpus > "$OUT/cpus.txt" 2>&1
cat "$OUT/cpus.txt"

echo "== 3/4 ANE 부분 부하: 초당 요청 수를 바꿔 가며 ${SAMPLE}초씩 (관리자 권한 없이) =="
"$PROBE" sample 8 "$OUT" ane-idle > "$OUT/ioreport-ane-idle.txt" 2> "$OUT/ioreport-ane-idle.log"
echo "   가만히: 기록함"
for rate in $RATES; do
  if [ "$rate" = 0 ]; then label="ane-rate-max"; else label="ane-rate-$rate"; fi
  "$LOAD" $((WARMUP + SAMPLE + 3)) ane "$rate" > "$OUT/load-$label.txt" 2>&1 &
  load_pid=$!
  sleep "$WARMUP"
  "$PROBE" sample "$SAMPLE" "$OUT" "$label" > "$OUT/ioreport-$label.txt" 2> "$OUT/ioreport-$label.log"
  wait "$load_pid"
  echo "   $label: $(tail -n 1 "$OUT/load-$label.txt")"
done

echo "== 4/4 powermetrics --show-extra-power-info (ANE 부하 중) =="
"$LOAD" 20 ane > "$OUT/load-extra.txt" 2>&1 &
load_pid=$!
sleep "$WARMUP"
sudo -n powermetrics --samplers cpu_power,gpu_power,ane_power --show-extra-power-info -i 1000 -n 3 \
  > "$OUT/pm-extra-power-info.txt" 2>&1
wait "$load_pid"
echo "   ANE가 들어간 줄 (첫 표본):"
awk '/\*\*\* Sampled system activity/{n++} n==1' "$OUT/pm-extra-power-info.txt" \
  | grep -i -E '(^|[^a-z])ane([^a-z]|$)|neural' | sed 's/^/   /'

echo "== 끝났어요. Claude에게 '3차 측정 끝났어'라고 알려 주세요 =="
