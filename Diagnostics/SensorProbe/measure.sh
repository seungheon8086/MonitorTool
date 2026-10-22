#!/bin/bash
# SensorProbe: 온도·팬·전력 센서를 읽기만 하는 진단이에요. 값을 바꾸는 명령은 쓰지 않아요.
# 가만히 → E코어 부하 → P코어 부하 → 식히기 → GPU 부하 → 식히기 → ANE 부하 → 식히기 순서로
# 센서를 1초마다 기록하고, 같은 시간 동안 powermetrics도 함께 기록해 비교해요. 5분쯤 걸려요.
# 사용법: 터미널에서 (앞에 sudo를 붙이지 마세요)
#   bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/SensorProbe/measure.sh

set -u
cd "$(dirname "$0")" || exit 1

if [ "$(id -u)" -eq 0 ]; then
  echo "sudo 없이 실행해 주세요. 센서는 관리자 권한 없이 읽히는지 확인해야 해서, powermetrics만 스크립트가 따로 sudo로 실행해요."
  exit 1
fi

OUT=results
mkdir -p "$OUT"

BIN_DIR="$(mktemp -d)"
PROBE="$BIN_DIR/sensor_probe"
BURN="$BIN_DIR/cpu_burn"
LOAD="$BIN_DIR/ane_load"

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
if ! swiftc -O sensor_probe.swift -o "$PROBE" >> "$OUT/build.txt" 2>&1 \
   || ! swiftc -O cpu_burn.swift -o "$BURN" >> "$OUT/build.txt" 2>&1 \
   || ! swiftc -O ../PowerProbe/ane_load.swift -o "$LOAD" >> "$OUT/build.txt" 2>&1; then
  echo "빌드 실패. $OUT/build.txt 내용:"
  cat "$OUT/build.txt"
  exit 1
fi

echo "== 2/4 센서 목록과 짧은 시험 실행 (관리자 권한 없이) =="
if ! "$PROBE" list "$OUT" > "$OUT/list.txt" 2> "$OUT/list.log"; then
  echo "센서 목록 단계에서 멈췄어요. Claude에게 알려 주세요. ($OUT/list.log)"
  exit 1
fi
if ! "$PROBE" sample 2 "$BIN_DIR" smoke > "$OUT/smoke.txt" 2>&1; then
  echo "시험 실행에서 멈췄어요. Claude에게 알려 주세요. ($OUT/smoke.txt)"
  exit 1
fi
"$PROBE" ane-ioreg "$OUT" idle > "$OUT/ane-ioreg-idle.log" 2>&1
grep -E '^SMC 키|^첫 글자별|^총 ' "$OUT/list.txt" | sed 's/^/   /'

echo "== 관리자 암호를 한 번 입력해 주세요 (센서 값과 비교할 powermetrics에 써요) =="
sudo -v || exit 1
# 측정이 길어도 암호를 다시 묻지 않도록 sudo 인증 시간을 계속 연장해요.
( while true; do sudo -n true 2>/dev/null; sleep 30; done ) &

sw_vers > "$OUT/system.txt" 2>&1

# $1: 이름표, $2: 초 — 센서(권한 없이)와 powermetrics(관리자 권한)를 같은 시간 동안 기록
phase() {
  sudo -n powermetrics --samplers cpu_power,gpu_power,ane_power,thermal -i 1000 -n "$(( $2 + 1 ))" \
    > "$OUT/pm-$1.txt" 2>&1 &
  local pm_pid=$!
  "$PROBE" sample "$2" "$OUT" "$1" > "$OUT/sample-$1.txt" 2> "$OUT/sample-$1.log"
  wait "$pm_pid"
  echo "   $1 기록함"
}

echo "== 3/4 부하별 기록 (각 15~25초) =="
phase A-idle 20

"$BURN" 30 background 4 > "$OUT/load-B-ecore.txt" 2>&1 &
load_pid=$!
sleep 2
phase B-ecore 25
wait "$load_pid"

"$BURN" 30 user 8 > "$OUT/load-C-pcore.txt" 2>&1 &
load_pid=$!
sleep 2
phase C-pcore 25
wait "$load_pid"

phase C2-cool 15

"$LOAD" 32 gpu > "$OUT/load-D-gpu.txt" 2>&1 &
load_pid=$!
sleep 4
phase D-gpu 25
wait "$load_pid"

phase D2-cool 15

"$LOAD" 36 ane > "$OUT/load-E-ane.txt" 2>&1 &
load_pid=$!
sleep 4
"$PROBE" ane-ioreg "$OUT" ane-load > "$OUT/ane-ioreg-ane-load.log" 2>&1
phase E-ane 25
wait "$load_pid"

echo "== 4/4 식히기 기록 =="
phase F-cool 20

echo "== 끝났어요. Claude에게 '센서 측정 끝났어'라고 알려 주세요 =="
