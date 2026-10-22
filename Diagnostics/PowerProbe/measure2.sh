#!/bin/bash
# PowerProbe 2차: powermetrics의 숨긴 정보, 관리자 권한 없이 읽는 IOReport,
# E/P·GPU 사용률 후보를 한 번에 확인해요. 5분쯤 걸려요.
# 사용법: 터미널에서 (앞에 sudo를 붙이지 마세요)
#   bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/PowerProbe/measure2.sh

set -u
cd "$(dirname "$0")" || exit 1

if [ "$(id -u)" -eq 0 ]; then
  echo "sudo 없이 실행해 주세요. 관리자 권한 없이 읽히는지 확인하는 단계가 있어서, 필요한 부분만 스크립트가 따로 sudo로 실행해요."
  exit 1
fi

OUT=results-2
mkdir -p "$OUT"

SAMPLERS="cpu_power,gpu_power,ane_power"
WARMUP=6   # 부하가 자리 잡을 때까지 기다리는 시간(초)

BIN_DIR="$(mktemp -d)"
LOAD="$BIN_DIR/ane_load"
PROBE="$BIN_DIR/ioreport_probe"
LOAD_PID=""
PM_PID=""

cleanup() {
  for pid in $(jobs -p); do
    kill "$pid" 2>/dev/null
  done
  rm -rf "$BIN_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "== 1/9 진단 도구 빌드 (1분쯤) =="
: > "$OUT/build.txt"
if ! swiftc -O ane_load.swift -o "$LOAD" >> "$OUT/build.txt" 2>&1 \
   || ! swiftc -O ioreport_probe.swift -o "$PROBE" >> "$OUT/build.txt" 2>&1; then
  echo "빌드 실패. $OUT/build.txt 내용:"
  cat "$OUT/build.txt"
  exit 1
fi

echo "== 관리자 암호를 한 번 입력해 주세요 (중간에 powermetrics와 비교해요) =="
sudo -v || exit 1
# 측정이 길어도 암호를 다시 묻지 않도록 sudo 인증 시간을 계속 연장해요.
( while true; do sudo -n true 2>/dev/null; sleep 30; done ) &

sw_vers > "$OUT/system.txt" 2>&1

probe() {        # $1: 이름표, $2: 초 — 관리자 권한 없이 IOReport·OS 통계 기록
  "$PROBE" sample "$2" "$OUT" "$1" > "$OUT/ioreport-$1.txt" 2> "$OUT/ioreport-$1.log"
  echo "   → $OUT/ioreport-$1.txt"
}

start_load() {   # $1: 장치(ane·gpu·cpu), $2: 초, $3: 기록 이름
  "$LOAD" "$2" "$1" > "$OUT/load-$3.txt" 2>&1 &
  LOAD_PID=$!
  sleep "$WARMUP"
}

start_pm() {     # $1: 기록 이름, $2: 횟수 — 1초 간격 powermetrics를 뒤에서 실행
  sudo -n powermetrics --samplers "$SAMPLERS" -i 1000 -n "$2" > "$OUT/pm-$1.txt" 2>&1 &
  PM_PID=$!
}

echo "== 2/9 IOReport 채널 목록과 짧은 시험 실행 =="
if ! "$PROBE" list "$OUT" > "$OUT/channels-summary.txt" 2> "$OUT/channels.log"; then
  echo "채널 목록 단계에서 멈췄어요. Claude에게 알려 주세요. ($OUT/channels.log)"
  exit 1
fi
# 본 측정 전에 2초만 돌려서 기록 단계가 문제없이 끝나는지 확인해요.
if ! "$PROBE" sample 2 "$BIN_DIR" smoke > "$OUT/smoke.txt" 2>&1; then
  echo "시험 실행에서 멈췄어요. Claude에게 알려 주세요. ($OUT/smoke.txt)"
  exit 1
fi
echo "   → $OUT/channels-summary.txt"

echo "== 3/9 [A] 가만히, powermetrics 없이 (20초) =="
probe A-idle 20

echo "== 4/9 [B] ANE 부하, powermetrics 없이 (30초) =="
start_load ane 40 B-ane
probe B-ane 30
wait "$LOAD_PID"

echo "== 5/9 [C] ANE 부하 + powermetrics 동시 실행 (20초) =="
start_load ane 30 C-ane
start_pm C-ane 22
probe C-ane-pm 20
wait "$PM_PID"; wait "$LOAD_PID"

echo "== 6/9 [D] CPU 부하 + powermetrics (20초): E/P 사용률 비교 =="
start_load cpu 30 D-cpu
start_pm D-cpu 22
probe D-cpu-pm 20
wait "$PM_PID"; wait "$LOAD_PID"

echo "== 7/9 [E] GPU 부하 + powermetrics (20초): GPU 사용률 비교 =="
start_load gpu 30 E-gpu
start_pm E-gpu 22
probe E-gpu-pm 20
wait "$PM_PID"; wait "$LOAD_PID"

echo "== 8/9 [H] powermetrics 숨긴 정보: 가만히 → ANE 부하 =="
sudo -n powermetrics --samplers "$SAMPLERS" --unhide-info "$SAMPLERS" -i 1000 -n 5 \
  > "$OUT/pm-H-unhide-idle.txt" 2>&1
start_load ane 30 H-ane
sudo -n powermetrics --samplers "$SAMPLERS" --unhide-info "$SAMPLERS" -i 1000 -n 5 \
  > "$OUT/pm-H-unhide-ane.txt" 2>&1
sudo -n powermetrics --samplers "$SAMPLERS" --unhide-info "$SAMPLERS" -i 1000 -n 3 -f plist \
  > "$OUT/pm-H-unhide-ane.plist" 2>&1
# --show-all은 프로세스 목록까지 나와서, 구역 제목과 ANE·Neural이 들어간 줄만 남겨요.
sudo -n powermetrics --show-all -i 1000 -n 2 2> "$OUT/pm-H-show-all.err" \
  | grep -i -E '^\*\*\*|(^|[^a-z])ane([^a-z]|$)|neural' > "$OUT/pm-H-show-all-ane-lines.txt"
wait "$LOAD_PID"
echo "   → $OUT/pm-H-*.txt"

echo "== 9/9 [F] 다시 가만히, powermetrics가 끝난 뒤 (20초) =="
sleep 5
probe F-idle-after 20

echo "== 끝났어요. Claude에게 '2차 측정 끝났어'라고 알려 주세요 =="
