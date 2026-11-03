#!/bin/bash
# DiskProbe 측정. 사용법: ./measure.sh [외장 디스크 볼륨 경로]
# 관리자 권한 필요 없음. 약 3분(외장 디스크를 주면 약 4분).
set -euo pipefail
cd "$(dirname "$0")"

EXT="${1:-}"
OUT="results/$(date +%Y%m%d-%H%M%S)"
P=build/diskprobe
WORK="${TMPDIR:-/tmp}/diskprobe-$$"
EXTF=""
SAMPLER=""
DMG_DEV=""

cleanup() {
  if [[ -n "$SAMPLER" ]]; then kill "$SAMPLER" 2>/dev/null || true; fi
  if [[ -n "$DMG_DEV" ]]; then hdiutil detach "$DMG_DEV" -quiet 2>/dev/null || true; fi
  rm -rf "$WORK"
  if [[ -n "$EXTF" ]]; then rm -f "$EXTF"; fi
}
trap cleanup EXIT

mkdir -p "$OUT" build "$WORK"

echo "▶ 빌드"
xcrun swiftc -O -o "$P" diskprobe.swift

avail_kb=$(df -k "$WORK" | awk 'NR==2 {print $4}')
if (( avail_kb < 6 * 1024 * 1024 )); then
  echo "내장 디스크 여유 공간이 6 GB보다 작아서 멈춥니다"; exit 1
fi
if [[ -n "$EXT" ]]; then
  if [[ ! -d "$EXT" || ! -w "$EXT" ]]; then echo "외장 디스크 경로에 쓸 수 없음: $EXT"; exit 1; fi
  EXTF="$EXT/.diskprobe-$$.bin"
fi

echo "▶ 시험 실행"
"$P" write "$WORK/test.bin" 1 64 64 > /dev/null
"$P" randread "$WORK/test.bin" 1 2 4 > /dev/null
rm -f "$WORK/test.bin"

echo "▶ 디스크 목록"
"$P" list > "$OUT/disks.txt"

printf 'phase\tstart\tend\tbytes\tops\n' > "$OUT/phases.tsv"
run() {
  local name="$1"; shift
  echo "▶ $name"
  printf '%s\t' "$name" >> "$OUT/phases.tsv"
  "$P" "$@" >> "$OUT/phases.tsv"
}

"$P" sample 100000 "$OUT/samples.tsv" 1 &
SAMPLER=$!

run "가만히" idle 20
run "순차 쓰기 1MiB" write "$WORK/load.bin" 15 4096 8192
run "쉼" idle 5
run "순차 읽기 1MiB" read "$WORK/load.bin" 15
run "쉼" idle 5
run "무작위 읽기 4KiB 스레드 1" randread "$WORK/load.bin" 15 1 4
run "쉼" idle 5
run "무작위 읽기 4KiB 스레드 8" randread "$WORK/load.bin" 15 8 4
run "쉼" idle 5
run "무작위 읽기 4KiB 스레드 32" randread "$WORK/load.bin" 15 32 4
run "쉼" idle 5
rm -f "$WORK/load.bin"

if [[ -n "$EXTF" ]]; then
  run "외장 순차 쓰기 1MiB" write "$EXTF" 15 2048 4096
  run "쉼" idle 5
  run "외장 순차 읽기 1MiB" read "$EXTF" 15
  run "쉼" idle 5
  run "외장 무작위 읽기 4KiB 스레드 8" randread "$EXTF" 15 8 4
  run "쉼" idle 5
  rm -f "$EXTF"
fi

echo "▶ 디스크 이미지 연결"
hdiutil create -size 64m -fs APFS -volname DiskProbeImage "$WORK/img.dmg" -quiet
mkdir -p "$WORK/mnt"
DMG_DEV=$(hdiutil attach "$WORK/img.dmg" -nobrowse -mountpoint "$WORK/mnt" | awk 'NR==1 {print $1}')
sleep 6
"$P" list > "$OUT/disks-with-image.txt"
run "디스크 이미지 쓰기" write "$WORK/mnt/x.bin" 3 32 48
run "쉼" idle 5
hdiutil detach "$DMG_DEV" -quiet
DMG_DEV=""

run "가만히 (끝)" idle 10
kill "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true
SAMPLER=""

echo "▶ 끝. 결과: Diagnostics/DiskProbe/$OUT"
