#!/bin/bash
# 가만히 있을 때와 ANE·GPU·CPU에 각각 부하를 줬을 때의 powermetrics 출력을 기록해요.
# 사용법: 터미널에서
#   bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/PowerProbe/measure.sh

set -u
cd "$(dirname "$0")" || exit 1
mkdir -p results

SAMPLERS="cpu_power,gpu_power,ane_power"
SAMPLES=10        # 측정 횟수 (1초 간격)
LOAD_SECONDS=30   # 부하를 주는 시간
WARMUP=8          # 부하가 자리 잡을 때까지 기다리는 시간

echo "== 1/5 부하 생성기 빌드 =="
BIN="$(mktemp -d)/ane_load"
if ! swiftc -O ane_load.swift -o "$BIN" > results/build.txt 2>&1; then
  echo "빌드 실패. results/build.txt 내용:"
  cat results/build.txt
  exit 1
fi

echo "== 관리자 암호를 한 번 입력해 주세요 (powermetrics는 관리자 권한이 필요해요) =="
sudo -v || exit 1

{
  sw_vers
  sysctl hw.model machdep.cpu.brand_string \
         hw.perflevel0.name hw.perflevel0.logicalcpu \
         hw.perflevel1.name hw.perflevel1.logicalcpu
} > results/system.txt 2>&1
sudo powermetrics -h > results/help.txt 2>&1

measure() {   # $1: 결과 이름
  sudo powermetrics --samplers "$SAMPLERS" -i 1000 -n "$SAMPLES" > "results/$1.txt" 2>&1
  sudo powermetrics --samplers "$SAMPLERS" -i 1000 -n 3 -f plist > "results/$1.plist" 2>&1
  echo "   → results/$1.txt"
}

echo "== 2/5 가만히 있을 때 =="
measure idle

step=3
for target in ane gpu cpu; do
  echo "== $step/5 $target 부하 =="
  "$BIN" "$LOAD_SECONDS" "$target" > "results/load-$target-run.txt" 2>&1 &
  load_pid=$!
  sleep "$WARMUP"
  measure "load-$target"
  wait "$load_pid"
  tail -n 1 "results/load-$target-run.txt"
  step=$((step + 1))
done

echo "== 끝났어요. Claude에게 '측정 끝났어'라고 알려 주세요 =="
