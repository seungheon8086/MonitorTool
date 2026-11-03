#!/bin/bash
# SMART 진단. 관리자 권한 필요 없음. 약 1분. 사용법: ./measure-smart.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT="results/smart-$(date +%Y%m%d-%H%M%S)"
WORK="${TMPDIR:-/tmp}/smartprobe-$$"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$OUT" build "$WORK"

SDK=$(xcrun --show-sdk-path)
HDR="$SDK/System/Library/Frameworks/IOKit.framework/Headers/storage/nvme/NVMeSMARTLibExternal.h"
if [[ ! -f "$HDR" ]]; then
  echo "SDK에 NVMe SMART 헤더가 없음: $HDR" | tee "$OUT/error.txt"
  ls "$SDK/System/Library/Frameworks/IOKit.framework/Headers/storage/" >> "$OUT/error.txt" 2>&1 || true
  exit 1
fi

echo "▶ 빌드"
xcrun clang -O2 -Wall -o build/smart_probe smart_probe.c -framework IOKit -framework CoreFoundation
if [[ ! -x build/diskprobe ]]; then xcrun swiftc -O -o build/diskprobe diskprobe.swift; fi

echo "▶ SMART 읽기 (1)"
build/smart_probe > "$OUT/before.tsv"
cat "$OUT/before.tsv"

echo "▶ 1 GiB 쓰기"
printf 'start\tend\tbytes\tops\n' > "$OUT/write.tsv"
build/diskprobe write "$WORK/w.bin" 30 1024 1024 >> "$OUT/write.tsv"
rm -f "$WORK/w.bin"

echo "▶ 20초 기다림"
sleep 20
echo "▶ SMART 읽기 (2)"
build/smart_probe > "$OUT/after.tsv"

if command -v smartctl > /dev/null; then
  echo "▶ smartctl 비교"
  smartctl -a disk0 2>&1 | grep -v -i 'serial' > "$OUT/smartctl.txt" || true
fi

echo "▶ 끝. 결과: Diagnostics/DiskProbe/$OUT"
