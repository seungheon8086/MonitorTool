#!/bin/bash
# GPU 온도 9.2 °C 확인 (macOS 27.2, 2026-10-30)
# 앱의 'GPU 최고'(Tg05·Tg0D)가 원래 센서(Tg04·Tg0C)에 9.2를 더한 값인지,
# 9.2 °C가 나올 때 원래 센서가 0(꺼짐)인지 확인해요. 관리자 권한 없이 센서를 읽기만 해요.
# 60초 동안 1초마다 기록해요. 그동안 Mac은 가만히 두세요(게임 등 GPU를 쓰는 앱은 꺼 주세요).
# 사용법: bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/SensorProbe/check_gpu_offset.sh

set -u
cd "$(dirname "$0")" || exit 1
OUT=results-272
mkdir -p "$OUT"
BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$BIN_DIR"' EXIT

echo "== 1/2 빌드 =="
if ! swiftc -O sensor_probe.swift -o "$BIN_DIR/sensor_probe" > "$OUT/build.txt" 2>&1; then
  echo "빌드 실패. $OUT/build.txt 내용:"
  cat "$OUT/build.txt"
  exit 1
fi
{ sw_vers; sysctl -n hw.model; } > "$OUT/system.txt" 2>&1

echo "== 2/2 60초 기록 (가만히 두세요) =="
"$BIN_DIR/sensor_probe" sample 60 "$OUT" idle > "$OUT/sample-idle.txt" 2> "$OUT/sample-idle.log"
echo "== 끝났어요. Claude에게 'GPU 확인 끝났어'라고 알려 주세요 =="
