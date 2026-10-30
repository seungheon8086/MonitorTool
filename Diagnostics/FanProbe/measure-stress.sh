#!/bin/bash
# FanProbe 부하 시험: CPU 10코어 + GPU(Metal 계산) + ANE에 한꺼번에 부하를 준 채로
#   S) 시스템 제어 그대로 — 몇 °C에서 팬이 돌기 시작하고 어디까지 오르는지 (두 팬이 45초 이어서 돌거나 5분이 되면 끝)
#   M) 수동, 팬마다 다른 목표 (왼쪽 2,000 · 오른쪽 2,300 RPM) 25초 — 시스템이 제어를 도로 가져가는지
#   Z) 돌고 있는 팬에 정지(0) 15초 — 실제로 멈추는지 (98 °C가 되면 바로 끝)
#   R) 부하가 있는 채로 시스템 제어로 20초
#   C) 부하를 끄고 식는 모습 45초
# 최대 7분쯤 걸려요. 'long'을 붙이면 S 단계를 최대 20분, 두 팬이 2분 이어서 돌 때까지로 늘려요(최대 22분). 어댑터를 연결해 두세요. 끝나거나 중간에 멈춰도(Control-C 포함) 부하를 끄고 팬을 시스템 제어로 되돌려요.
# 사용법: 터미널에서 (앞에 sudo를 붙이지 마세요)
#   bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/FanProbe/measure-stress.sh [long]

set -u
cd "$(dirname "$0")" || exit 1

if [ "$(id -u)" -eq 0 ]; then
  echo "sudo 없이 실행해 주세요. 제어 단계만 스크립트가 따로 sudo로 실행해요."
  exit 1
fi

OUT=results
mkdir -p "$OUT"

SYSTEM_SECONDS=300
SPIN_SECONDS=45
NAME=stress
if [ "${1:-}" = "long" ]; then
  SYSTEM_SECONDS=1200
  SPIN_SECONDS=120
  NAME=stress-long
fi
LOAD_SECONDS=$(( SYSTEM_SECONDS + 300 ))

BIN_DIR="$(mktemp -d)"
PROBE="$BIN_DIR/fan_probe"
BURN="$BIN_DIR/cpu_burn"
GPUBURN="$BIN_DIR/gpu_burn"
LOAD="$BIN_DIR/ane_load"
CONTROL_STARTED=""
KEEPALIVE_PID=""
LOAD_PIDS=""
PM_PID=""

stop_loads() {
  if [ -n "$LOAD_PIDS" ]; then
    # shellcheck disable=SC2086
    kill $LOAD_PIDS 2>/dev/null
    # shellcheck disable=SC2086
    wait $LOAD_PIDS 2>/dev/null
    LOAD_PIDS=""
  fi
  if [ -n "$PM_PID" ]; then
    sudo -n kill "$PM_PID" 2>/dev/null
    wait "$PM_PID" 2>/dev/null
    PM_PID=""
  fi
}

cleanup() {
  stop_loads
  if [ -n "$CONTROL_STARTED" ]; then
    echo "== 팬을 시스템 제어로 되돌려요 =="
    if sudo -n "$PROBE" restore >> "$OUT/$NAME-restore.txt" 2>&1; then
      tail -n 1 "$OUT/$NAME-restore.txt" | sed 's/^/   /'
    else
      echo "⚠️ 되돌리기에 실패했어요. $OUT/stress-restore.txt를 Claude에게 알려 주세요. Mac을 재시동하면 시스템 제어로 돌아가요."
    fi
  fi
  if [ -n "$KEEPALIVE_PID" ]; then
    kill "$KEEPALIVE_PID" 2>/dev/null
  fi
  rm -rf "$BIN_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo "== 1/4 도구 빌드 (1분쯤) =="
: > "$OUT/$NAME-build.txt"
if ! swiftc -O -swift-version 5 fan_probe.swift -o "$PROBE" >> "$OUT/$NAME-build.txt" 2>&1 \
   || ! swiftc -O ../SensorProbe/cpu_burn.swift -o "$BURN" >> "$OUT/$NAME-build.txt" 2>&1 \
   || ! swiftc -O gpu_burn.swift -o "$GPUBURN" >> "$OUT/$NAME-build.txt" 2>&1 \
   || ! swiftc -O ../PowerProbe/ane_load.swift -o "$LOAD" >> "$OUT/$NAME-build.txt" 2>&1; then
  echo "빌드 실패. $OUT/stress-build.txt 내용:"
  cat "$OUT/$NAME-build.txt"
  exit 1
fi

others="$(pgrep -il 'Macs Fan Control|TG Pro|smcFanControl|FanBar|CurveFan|thermod|smctld' || true)"
if [ -n "$others" ]; then
  echo "다른 팬 제어 프로그램이 켜져 있어요. 끄고 다시 실행해 주세요:"
  echo "$others" | sed 's/^/   /'
  exit 1
fi

echo
echo "CPU 10코어·GPU·ANE에 최대 $(( SYSTEM_SECONDS / 60 + 1 ))분쯤 부하를 주고, 그동안 팬을 직접 바꿔 봐요."
echo "칩이 뜨거워지고 팬 소리가 나요. 어댑터를 연결하고, 무거운 작업(게임 등)은 꺼 주세요."
echo "계속하려면 Enter, 그만두려면 Control-C를 눌러 주세요."
read -r _

echo "== 2/4 관리자 암호를 한 번 입력해 주세요 (팬 제어에 써요) =="
sudo -v || exit 1
( while true; do sudo -n true 2>/dev/null; sleep 30; done ) &
KEEPALIVE_PID=$!

{ sw_vers; sysctl -n hw.model; pmset -g batt | head -1; } > "$OUT/$NAME-system.txt" 2>&1

if pmset -g batt | head -1 | grep -q 'Battery Power'; then
  echo "⚠️ 지금 배터리로 동작 중이에요. 어댑터를 연결하면 더 정확해요. (그대로 하려면 Enter)"
  read -r _
fi
if pmset -g | grep -Eq 'lowpowermode[[:space:]]+1'; then
  echo "⚠️ 저전력 모드가 켜져 있어요. 끄고 하는 게 좋아요. (그대로 하려면 Enter)"
  read -r _
fi

echo "== 3/4 부하 켜고 시험 (최대 $(( SYSTEM_SECONDS / 60 + 1 ))분) =="
"$BURN" "$LOAD_SECONDS" user 10 > "$OUT/$NAME-load-cpu.txt" 2>&1 &
LOAD_PIDS="$!"
"$GPUBURN" "$LOAD_SECONDS" > "$OUT/$NAME-load-gpu.txt" 2>&1 &
LOAD_PIDS="$LOAD_PIDS $!"
"$LOAD" "$LOAD_SECONDS" ane > "$OUT/$NAME-load-ane.txt" 2>&1 &
LOAD_PIDS="$LOAD_PIDS $!"
# 전력·열 압력 확인용 (5초마다)
sudo -n powermetrics --samplers cpu_power,gpu_power,ane_power,thermal -i 5000 -n "$(( LOAD_SECONDS / 5 ))" \
  > "$OUT/$NAME-pm.txt" 2>&1 &
PM_PID=$!
sleep 3
# shellcheck disable=SC2086
if ! kill -0 $LOAD_PIDS 2>/dev/null; then
  echo "부하 도구 하나가 바로 끝났어요. $OUT/$NAME-load-*.txt를 Claude에게 알려 주세요."
  exit 1
fi
CONTROL_STARTED=1
sudo -n "$PROBE" stress "$SYSTEM_SECONDS" "$SPIN_SECONDS" > "$OUT/$NAME.txt" 2> "$OUT/$NAME.log"
status=$?
stop_loads
grep -E '^# ' "$OUT/$NAME.txt" | sed 's/^/   /'
echo "   stress 종료 코드 $status"

echo "== 4/4 부하 끄고 식는 모습 기록 (45초) =="
"$PROBE" watch 45 C-식히기 >> "$OUT/$NAME.txt" 2>> "$OUT/$NAME.log"

echo "== 끝났어요. Claude에게 '부하 시험 끝났어'라고 알려 주세요 =="
