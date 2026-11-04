#!/bin/bash
# 3단계 공존 시험. run.sh coexist가 부른다 (root). 인자: 도구 경로, 결과 폴더, [고를 시험 글자들, 기본 BCDE]
# 차례: B 쥔 동안 다른 도구 → C 비켜주기 → D 강제 종료(kill -9) 뒤 → E 다른 도구가 쓰는 중에 시작
# 다른 도구의 출력에는 파일 경로가 들어 있어서 남기지 않는다(줄 수·종료 코드·오류 글만). xctrace 기록 파일도 크기만 보고 지운다.
# macOS의 bash 3.2에서 돈다
set -u
P="$1"
OUT="$2"
SEL="${3:-BCDE}"
TL="$OUT/timeline.txt"
: > "$TL"

log() {
  local line
  line="$("$P" stamp) [run] $*"
  echo "$line"
  echo "$line" >> "$TL"
}
state() { log "상태 ($1): $("$P" state)"; }

# 끝나거나 Ctrl-C면 남은 hold를 멈춘다
cleanup() {
  local p
  for p in $(jobs -p); do kill -INT "$p" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT

# fs_usage <이름표> <초>: -t로 스스로 끝난다. 다른 도구가 쥐고 있으면 'ktrace_start: Resource busy'로 바로 끝난다
run_fs_usage() {
  local tag="$1" secs="$2" raw rc lines err
  raw=$(mktemp -t dap-fsu)
  log "fs_usage $tag 시작 (-w -f diskio -t $secs)"
  /usr/bin/fs_usage -w -f diskio -t "$secs" > "$raw" 2> "$OUT/fs_usage-$tag.err"
  rc=$?
  lines=$(wc -l < "$raw" | tr -d ' ')
  rm -f "$raw"
  err=$(head -c 300 "$OUT/fs_usage-$tag.err" | tr '\n' ' ')
  [[ -s "$OUT/fs_usage-$tag.err" ]] || rm -f "$OUT/fs_usage-$tag.err"
  log "fs_usage $tag 끝: 종료 코드 $rc · 출력 ${lines}줄 · 오류: ${err:-없음}"
}

XCT=""
if XCT=$(xcrun --find xctrace 2>/dev/null) && [[ -x "$XCT" ]]; then
  XCT_EXTRA=""
  if "$XCT" help record 2>&1 | grep -q -- '--no-prompt'; then XCT_EXTRA="--no-prompt"; fi
else
  XCT=""
fi

# xctrace <이름표> <초>: Time Profiler(모든 프로세스)를 짧게 기록한다. 60초가 지나면 멈춘다
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

log "== 3단계 공존 시험 · $(sw_vers -productVersion) · $(sysctl -n hw.model)"
log "tailspin: $(/usr/bin/tailspin info 2>&1 | grep -m1 .)"
log "powermetrics: $(pgrep -x powermetrics | tr '\n' ' ')"
if [[ -n "$XCT" ]]; then log "xctrace: $XCT ${XCT_EXTRA}"; else log "xctrace: 없음 (Xcode가 없으면 건너뜀)"; fi
log "고른 시험: $SEL"
state "시작 전"

scenario_B() {
log "== B: 우리가 쥔 동안 다른 도구 (비켜주기 끔)"
"$P" hold "$OUT" B 40 0 > "$OUT/hold-B.out" 2>&1 &
HB=$!
sleep 4
state "B 잡은 뒤"
run_fs_usage B1 3
sleep 1
if [[ -n "$XCT" ]]; then
  run_xctrace B2 3
  sleep 1
fi
state "B 다른 도구 뒤"
kill -INT "$HB" 2>/dev/null
wait "$HB"
log "hold B 끝: 종료 코드 $?"
sleep 3
state "B 끝난 뒤"
}

# C: 추적 중에는 실행 이벤트로 도구를 보고 비켜준다. fs_usage는 보기 전에 실패할 것으로(첫 시도), 다음 시도는 돌 것으로 본다.
# xctrace는 시작이 느려서 첫 시도부터 돌 수 있다. 도구가 끝나고 10초 뒤 다시 잡는지도 본다
scenario_C() {
log "== C: 비켜주기 켬 (도구가 끝나고 10초 뒤 다시 잡음)"
"$P" hold "$OUT" C 120 1 10 > "$OUT/hold-C.out" 2>&1 &
HC=$!
sleep 4
state "C 잡은 뒤"
run_fs_usage C1 3
sleep 2
state "C1 뒤 (비켜줬는지)"
run_fs_usage C2 3
sleep 14
state "C 다시 잡았는지"
if [[ -n "$XCT" ]]; then
  run_xctrace C3 3
  sleep 14
  state "C xctrace 뒤 다시 잡았는지"
fi
kill -INT "$HC" 2>/dev/null
wait "$HC"
log "hold C 끝: 종료 코드 $?"
sleep 3
state "C 끝난 뒤"
}

scenario_D() {
log "== D: 강제 종료 (kill -9)"
"$P" hold "$OUT" D1 60 0 > "$OUT/hold-D1.out" 2>&1 &
HD=$!
sleep 4
kill -9 "$HD" 2>/dev/null
wait "$HD" 2>/dev/null
log "hold D1에 kill -9 (종료 코드 $?)"
sleep 1
state "D1 죽은 뒤"
log "hold D2: 남은 추적을 정리하고 잡는지 (6초)"
"$P" hold "$OUT" D2 6 0 > "$OUT/hold-D2.out" 2>&1
log "hold D2 끝: 종료 코드 $?"
sleep 3
state "D2 끝난 뒤"
"$P" hold "$OUT" D3 60 0 > "$OUT/hold-D3.out" 2>&1 &
HD=$!
sleep 4
kill -9 "$HD" 2>/dev/null
wait "$HD" 2>/dev/null
log "hold D3에 kill -9 (종료 코드 $?)"
sleep 1
state "D3 죽은 뒤"
run_fs_usage D4 3
sleep 3
state "D4 fs_usage 뒤 (남은 추적을 fs_usage가 가져갔는지)"
log "reset: $("$P" reset 2>&1 | tr '\n' ' ')"
state "D 정리 뒤"
}

scenario_E() {
log "== E: fs_usage가 쓰는 중에 우리가 시작"
run_fs_usage E1 10 &
HF=$!
sleep 2
state "E fs_usage 도는 중"
"$P" hold "$OUT" E 16 0 > "$OUT/hold-E.out" 2>&1
log "hold E 끝: 종료 코드 $?"
wait "$HF"
sleep 3
}

case "$SEL" in *B*) scenario_B ;; esac
case "$SEL" in *C*) scenario_C ;; esac
case "$SEL" in *D*) scenario_D ;; esac
case "$SEL" in *E*) scenario_E ;; esac

state "끝"
log "reset: $("$P" reset 2>&1 | tr '\n' ' ')"
log "tailspin: $(/usr/bin/tailspin info 2>&1 | grep -m1 .)"
log "powermetrics: $(pgrep -x powermetrics | tr '\n' ' ')"
log "== 끝"
