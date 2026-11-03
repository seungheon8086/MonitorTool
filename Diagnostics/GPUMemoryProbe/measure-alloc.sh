#!/bin/bash
# GPUMemoryProbe 2: 'Alloc system memory'가 할당량인지(정해진 크기 할당 시험)와,
# 가만히 있을 때 값이 큰 이유(켜 둔 앱 때문인지)를 확인해요. sudo 필요 없어요.
# 사용법: bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/GPUMemoryProbe/measure-alloc.sh

set -u
cd "$(dirname "$0")" || exit 1
OUT=results-2
mkdir -p "$OUT"
BIN="$(mktemp -d)/gpu_alloc"
trap 'rm -rf "$(dirname "$BIN")"' EXIT

alloc_now() {
  ioreg -r -c IOAccelerator -w0 -l | grep -m1 '"PerformanceStatistics"' \
    | grep -o '"Alloc system memory"=[0-9]*' | awk -F= '{printf "%.3f GB", $2/1e9}'
}
apps_now() {   # GPU에 연결된 프로세스 이름
  ioreg -r -c IOAccelerator -w0 -l | grep -o '"IOUserClientCreator" = "[^"]*"' \
    | sed 's/.*pid [0-9]*, //; s/"$//' | sort | uniq -c | sort -rn
}

echo "== 1/3 시험 프로그램 빌드 =="
if ! swiftc -O gpu_alloc.swift -o "$BIN" > "$OUT/build.txt" 2>&1; then
  echo "빌드 실패:"; cat "$OUT/build.txt"; exit 1
fi
{ sw_vers; sysctl -n machdep.cpu.brand_string; date; } > "$OUT/system.txt" 2>&1

echo "== 2/3 GPU 메모리 1 GiB·2 GiB 할당 시험 (20초쯤) =="
"$BIN" | tee "$OUT/alloc-test.txt"

echo
echo "== 3/3 (선택) 앱을 닫았을 때 가만히 값 =="
apps_now > "$OUT/apps-before.txt"
echo "지금 Alloc: $(alloc_now)  (GPU에 연결된 프로세스 $(wc -l < "$OUT/apps-before.txt")종류)" | tee "$OUT/idle.txt"
echo "Chrome·Discord·Telegram·Safari·Xcode 등 쓰지 않는 앱을 닫은 뒤 Enter를 눌러 주세요."
echo "(건너뛰려면 s 입력 후 Enter. MonitorTool·터미널은 켜 둬요)"
read -r answer
if [ "$answer" != s ]; then
  sleep 5
  apps_now > "$OUT/apps-after.txt"
  echo "앱을 닫은 뒤 Alloc: $(alloc_now)  (GPU에 연결된 프로세스 $(wc -l < "$OUT/apps-after.txt")종류)" | tee -a "$OUT/idle.txt"
fi
echo
echo "== 끝났어요. Claude에게 '할당 시험 끝났어'라고 알려 주세요 =="
