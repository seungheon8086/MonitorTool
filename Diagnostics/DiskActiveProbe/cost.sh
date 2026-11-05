#!/bin/bash
# 4단계 비용 시험. run.sh cost가 부른다 (root). 인자: 도구 경로, 결과 폴더
# 먼저 시스템 콜 한 번의 시간을 평소와 우리가 쥔 동안 번갈아 잰다(추적이 켜지면 커널의 추적 지점마다 형식 필터를 거침).
# 읽는 방식(100·250·500·1000 ms마다, w = 버퍼 기준치 대기)마다 가만히 20초 → 무거운 부하 12초(4 KiB 무작위 읽기 동시 32, 따로 된 프로세스).
# 그다음 읽기 버퍼를 8,192개(512 KiB)로 줄여 가만히 20초, 끝으로 w에서 비켜주기가 xctrace 첫 시도에 맞는지 본다.
# hold마다 hold-<이름표>.txt, 모두 모은 표는 holds.tsv. macOS의 bash 3.2에서 돈다
set -u
P="$1"
OUT="$2"
TL="$OUT/timeline.txt"
WORK="$OUT/work.bin"
: > "$TL"

log() {
  local line
  line="$("$P" stamp) [run] $*"
  echo "$line"
  echo "$line" >> "$TL"
}
state() { log "상태 ($1): $("$P" state)"; }

cleanup() {
  local p
  for p in $(jobs -p); do kill -INT "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -f "$WORK"
}
trap cleanup EXIT
# Ctrl-C면 지금 하던 hold만이 아니라 시험 전체를 멈춘다 (hold는 신호를 받아 정상으로 끝나므로 bash가 그냥 이어 가지 않게)
trap 'log "Ctrl-C: 시험을 멈춤"; exit 130' INT TERM

XCT=""
if XCT=$(xcrun --find xctrace 2>/dev/null) && [[ -x "$XCT" ]]; then
  XCT_EXTRA=""
  if "$XCT" help record 2>&1 | grep -q -- '--no-prompt'; then XCT_EXTRA="--no-prompt"; fi
else
  XCT=""
fi

run_xctrace() {
  local tag="$1" secs="$2" dir rc size waited pid err
  dir=$(mktemp -d -t dap-xct)
  log "xctrace $tag 시작 (Time Profiler · 모든 프로세스 · ${secs}초)"
  "$XCT" record --template 'Time Profiler' --all-processes --time-limit "${secs}s" --output "$dir/t.trace" $XCT_EXTRA \
    > "$OUT/xctrace-$tag.out" 2> "$OUT/xctrace-$tag.err" < /dev/null &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 600 )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "xctrace $tag 60초가 지나 멈춤"
    kill -INT "$pid" 2>/dev/null
    sleep 3
    kill -KILL "$pid" 2>/dev/null
  fi
  wait "$pid"
  rc=$?
  size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
  rm -rf "$dir"
  err=$(head -c 300 "$OUT/xctrace-$tag.err" | tr '\n' ' ')
  [[ -s "$OUT/xctrace-$tag.err" ]] || rm -f "$OUT/xctrace-$tag.err"
  log "xctrace $tag 끝: 종료 코드 $rc · 기록 ${size:-0} KB (지움) · 오류: ${err:-없음}"
}

log "== 4단계 비용 시험 · $(sw_vers -productVersion) · $(sysctl -n hw.model)"
log "tailspin: $(/usr/bin/tailspin info 2>&1 | grep -m1 .)"
log "powermetrics: $(pgrep -x powermetrics | tr '\n' ' ')"
state "시작 전"

log "== 시스템 콜 비용 (getppid 3초씩): 평소 → 우리가 쥔 동안(1000 ms마다 읽기) 두 번 → 평소"
log "평소 1: $("$P" work - syscall 0 3)"
"$P" hold "$OUT" sys-1000 10 0 10 1000 > "$OUT/hold-sys-1000.out" 2>&1 &
H=$!
sleep 2
state "쥔 동안"
log "쥔 동안 1: $("$P" work - syscall 0 3)"
log "쥔 동안 2: $("$P" work - syscall 0 3)"
wait "$H"
sleep 3
state "놓은 뒤"
log "평소 2: $("$P" work - syscall 0 3)"

log "부하 파일: $("$P" work "$WORK" prepare 1024 60)"

for m in 100 250 500 1000 w; do
  log "== 읽기 $m · 가만히 20초"
  "$P" hold "$OUT" "idle-$m" 20 0 10 "$m" > "$OUT/hold-idle-$m.out" 2>&1
  log "== 읽기 $m · 부하 12초 (4 KiB 무작위 읽기 동시 32를 10초)"
  "$P" hold "$OUT" "load-$m" 12 0 10 "$m" > "$OUT/hold-load-$m.out" 2>&1 &
  H=$!
  sleep 1
  log "부하: $("$P" work "$WORK" randread 32 10)"
  wait "$H"
  sleep 2
done

log "== 읽기 버퍼 줄이기 · 1000 ms마다 · 한 번에 8,192개(512 KiB) · 가만히 20초"
"$P" hold "$OUT" idle-1000-small 20 0 10 1000 8192 > "$OUT/hold-idle-1000-small.out" 2>&1

if [[ -n "$XCT" ]]; then
  log "== 버퍼 기준치 대기(w)에서 비켜주기 · xctrace 첫 시도"
  "$P" hold "$OUT" yield-w 90 1 10 w > "$OUT/hold-yield-w.out" 2>&1 &
  H=$!
  sleep 4
  state "w 잡은 뒤"
  run_xctrace W1 3
  sleep 12
  state "xctrace 뒤 다시 잡았는지"
  kill -INT "$H" 2>/dev/null
  wait "$H"
  log "hold yield-w 끝: 종료 코드 $?"
else
  log "xctrace 없음: 비켜주기 확인은 건너뜀"
fi

rm -f "$WORK"
sleep 2
state "끝"
log "reset: $("$P" reset 2>&1 | tr '\n' ' ')"
log "powermetrics: $(pgrep -x powermetrics | tr '\n' ' ')"
log "== 끝"
