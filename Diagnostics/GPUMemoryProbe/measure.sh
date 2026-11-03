#!/bin/bash
# GPUMemoryProbe: GPU가 쓰는 메모리 값을 관리자 권한 없이 읽을 수 있는지 확인해요.
#  - IORegistry IOAccelerator의 PerformanceStatistics 전체 키를 한 번 기록
#  - 가만히 10초 → GPU 부하 15초 → 끝난 뒤 10초 동안 1초마다 기록 (값이 GPU 사용에 따라 움직이는지)
# 1분쯤 걸려요. sudo 필요 없어요.
# 사용법: bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/GPUMemoryProbe/measure.sh

set -u
cd "$(dirname "$0")" || exit 1
OUT=results
mkdir -p "$OUT"
BIN_DIR="$(mktemp -d)"
LOAD="$BIN_DIR/ane_load"
trap 'for p in $(jobs -p); do kill "$p" 2>/dev/null; done; rm -rf "$BIN_DIR"' EXIT
trap 'exit 130' INT TERM

echo "== 1/3 GPU 부하 생성기 빌드 (PowerProbe의 ane_load) =="
if ! swiftc -O ../PowerProbe/ane_load.swift -o "$LOAD" > "$OUT/build.txt" 2>&1; then
  echo "빌드 실패:"; cat "$OUT/build.txt"; exit 1
fi
{ sw_vers; sysctl -n machdep.cpu.brand_string; sysctl -n hw.memsize; date; } > "$OUT/system.txt" 2>&1

# IOAccelerator 클래스로 못 찾으면 전체 IORegistry에서 찾아요.
stats_line() {
  local line
  line=$(ioreg -r -c IOAccelerator -w0 -l 2>/dev/null | grep -m1 '"PerformanceStatistics"')
  [ -z "$line" ] && line=$(ioreg -w0 -l 2>/dev/null | grep -m1 '"PerformanceStatistics"')
  printf '%s' "$line"
}

echo "== 2/3 PerformanceStatistics 전체 키 =="
ioreg -r -c IOAccelerator -w0 -l > "$OUT/ioaccelerator.txt" 2>&1
stats_line > "$OUT/stats-first.txt"
tr ',{}' '\n\n\n' < "$OUT/stats-first.txt" | sed 's/^ *//' | grep '=' | tee "$OUT/keys.txt"

sample() {   # $1 이름표, $2 초
  local i
  for ((i = 0; i < $2; i++)); do
    printf '%s\t%s\t%s\n' "$1" "$(date +%s)" \
      "$(stats_line | sed 's/.*"PerformanceStatistics" = //')"
    sleep 1
  done
}

echo "== 3/3 가만히 10초 → GPU 부하 15초 → 끝난 뒤 10초 =="
: > "$OUT/samples.tsv"
sample idle 10 >> "$OUT/samples.tsv"
"$LOAD" 18 gpu > "$OUT/load-gpu.txt" 2>&1 &
sleep 2
sample gpu 15 >> "$OUT/samples.tsv"
wait
sample after 10 >> "$OUT/samples.tsv"

echo
echo "이름표 | Device Utilization % | In use system memory | Alloc system memory (바이트)"
awk -F'\t' '{ u=m=a="-";
  if (match($3, /"Device Utilization %"=[0-9]+/)) { u=substr($3, RSTART+23, RLENGTH-23) }
  if (match($3, /"In use system memory"=[0-9]+/)) { m=substr($3, RSTART+23, RLENGTH-23) }
  if (match($3, /"Alloc system memory"=[0-9]+/)) { a=substr($3, RSTART+22, RLENGTH-22) }
  print $1 " | " u " | " m " | " a }' "$OUT/samples.tsv"
echo
echo "== 끝났어요. Claude에게 'GPU 메모리 측정 끝났어'라고 알려 주세요 =="
