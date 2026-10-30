#!/bin/bash
# FanProbe: 이 Mac에서 팬을 제어할 수 있는지 확인하는 진단이에요. 약 2분 걸려요.
#   1) 팬 관련 SMC 키 목록 (관리자 권한 없이)
#   2) 관리자 권한 없이 쓰기가 거절되는지 (지금 값을 그대로 다시 써서 값은 바뀌지 않아요)
#   3) 관리자 권한으로 수동 모드 → 2,500 → 3,500 → 2,000 RPM → 시스템 제어 복원 (약 1분 40초, 팬 소리가 나요)
# 끝나거나 중간에 멈춰도(Control-C 포함) 팬을 시스템 제어로 되돌려요.
# 사용법: 터미널에서 (앞에 sudo를 붙이지 마세요)
#   bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/FanProbe/measure.sh

set -u
cd "$(dirname "$0")" || exit 1

if [ "$(id -u)" -eq 0 ]; then
  echo "sudo 없이 실행해 주세요. 관리자 권한 없이 쓰기가 거절되는지도 확인해야 해서, 제어 단계만 스크립트가 따로 sudo로 실행해요."
  exit 1
fi

OUT=results
mkdir -p "$OUT"

BIN_DIR="$(mktemp -d)"
PROBE="$BIN_DIR/fan_probe"
CONTROL_STARTED=""
KEEPALIVE_PID=""

cleanup() {
  if [ -n "$CONTROL_STARTED" ]; then
    echo "== 팬을 시스템 제어로 되돌려요 =="
    if sudo -n "$PROBE" restore >> "$OUT/restore.txt" 2>&1; then
      tail -n 1 "$OUT/restore.txt" | sed 's/^/   /'
    else
      echo "⚠️ 되돌리기에 실패했어요. $OUT/restore.txt를 Claude에게 알려 주세요. Mac을 재시동하면 시스템 제어로 돌아가요."
    fi
  fi
  if [ -n "$KEEPALIVE_PID" ]; then
    kill "$KEEPALIVE_PID" 2>/dev/null
  fi
  rm -rf "$BIN_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo "== 1/4 진단 도구 빌드 =="
if ! swiftc -O -swift-version 5 fan_probe.swift -o "$PROBE" > "$OUT/build.txt" 2>&1; then
  echo "빌드 실패. $OUT/build.txt 내용:"
  cat "$OUT/build.txt"
  exit 1
fi

echo "== 2/4 팬 키 목록과 권한 없는 쓰기 시험 (관리자 권한 없이) =="
sw_vers > "$OUT/system.txt" 2>&1
sysctl -n hw.model >> "$OUT/system.txt" 2>&1
if ! "$PROBE" info > "$OUT/info.txt" 2> "$OUT/info.log"; then
  echo "키 목록 단계에서 멈췄어요. Claude에게 알려 주세요. ($OUT/info.log)"
  exit 1
fi
grep -E '^# (SMC 키|Ftst|F0md|FS!)' "$OUT/info.txt" | sed 's/^/   /'
"$PROBE" unpriv-write > "$OUT/unpriv-write.txt" 2>&1
grep -v '^#' "$OUT/unpriv-write.txt" | sed 's/^/   /'

# 다른 팬 제어 앱이 켜져 있으면 서로 같은 키를 바꾸게 되니 멈춰요.
others="$(pgrep -il 'Macs Fan Control|TG Pro|smcFanControl|FanBar|CurveFan|thermod|smctld' || true)"
if [ -n "$others" ]; then
  echo "다른 팬 제어 프로그램이 켜져 있어요. 끄고 다시 실행해 주세요:"
  echo "$others" | sed 's/^/   /'
  exit 1
fi

echo
echo "다음 단계에서 팬을 약 1분 40초 동안 2,000~3,500 RPM으로 돌려요(소리가 나요)."
echo "끝나면 시스템 제어로 되돌려요. 계속하려면 Enter, 그만두려면 Control-C를 눌러 주세요."
read -r _

echo "== 3/4 관리자 암호를 한 번 입력해 주세요 (팬 제어에 써요) =="
sudo -v || exit 1
( while true; do sudo -n true 2>/dev/null; sleep 30; done ) &
KEEPALIVE_PID=$!

echo "== 4/4 팬 제어 시험 (약 1분 40초) =="
CONTROL_STARTED=1
sudo -n "$PROBE" control > "$OUT/control.txt" 2> "$OUT/control.log"
status=$?
grep -E '^# (쓰기|복원|수동|온도)' "$OUT/control.txt" | sed 's/^/   /'
echo "   control 종료 코드 $status"

echo "== 끝났어요. Claude에게 '팬 진단 끝났어'라고 알려 주세요 =="
