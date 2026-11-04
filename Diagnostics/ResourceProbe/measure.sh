#!/bin/bash
# MonitorTool 가족(앱·보조 프로그램·powermetrics·위젯 확장)이 쓰는 연산량·에너지·메모리를 재요. (2026-11-04)
#
# 사용법 (터미널, sudo 없이. 처음에 관리자 암호를 한 번 물어요):
#   bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/ResourceProbe/measure.sh <이름>
#   예) measure.sh baseline
#
# 하는 일 (약 28분, SKIP_BUILD=1이면 약 25분)
#  1. 측정 도구(rusage_probe.swift) 컴파일, 2초 시험
#  2. Scripts/build-app.sh로 지금 코드를 Release로 빌드해 /Applications에 설치하고, macOS가 새 앱을 색인하는 동안
#     3분 기다림 (건너뛰기: SKIP_BUILD=1, 설치된 앱 그대로)
#     그다음 앱을 껐다 켜서 보조 프로그램도 새로 띄움 (재설치 뒤에는 예전 앱의 보조 프로그램이 휴지통 경로로 남아 있을 수 있어서)
#  3. 패널 열림·고정: 패널을 열고 고정한 뒤 Enter → 1분 기다리고 10분 측정
#  4. 패널 닫힘: 앱을 종료했다 다시 켜고(패널 닫힘) 2분 기다린 뒤 10분 측정
#  (선택) 화면 꺼짐: SCREEN_OFF_SECONDS를 주면 화면을 끄고(pmset displaysleepnow) 30초 뒤 그만큼 측정
#  5. 결과: results/<날짜-시각>-<이름>/summary.txt
#     상황별 폴더(open·closed)에 summary.txt, totals.csv, samples.tsv.gz(2초마다 누적값), powermetrics.txt.gz,
#     측정 앞뒤 ps(before.txt·after.txt: 누적 CPU 시간 대조), 1분마다 CPU를 많이 쓴 다른 프로세스(noise.txt)
# 3·4단계 동안 caffeinate로 화면이 꺼지거나 잠들지 않게 해요. 그동안 Mac을 만지지 마세요.
# 전원은 측정끼리 같게 (2026-11-04 기준 측정은 배터리, 100%)
# 시간 바꾸기: MEASURE_SECONDS(기본 600), OPEN_SETTLE(60), CLOSED_SETTLE(120), POST_INSTALL_SETTLE(180),
#             SCREEN_OFF_SECONDS(기본 0 = 화면 꺼짐 측정 안 함)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NAME="${1:-run}"
MEASURE_SECONDS="${MEASURE_SECONDS:-600}"
OPEN_SETTLE="${OPEN_SETTLE:-60}"
CLOSED_SETTLE="${CLOSED_SETTLE:-120}"
POST_INSTALL_SETTLE="${POST_INSTALL_SETTLE:-180}"
SCREEN_OFF_SECONDS="${SCREEN_OFF_SECONDS:-0}"
APP="/Applications/MonitorTool.app"
APP_ID="com.seungheon.MonitorTool"
# launchd가 BundleProgram 상대 경로로 띄워서 명령줄이 'Contents/MacOS/MonitorToolHelper'예요.
HELPER_PATTERN="Contents/MacOS/MonitorToolHelper"
WORK="$ROOT/build/ResourceProbe"
PROBE="$WORK/rusage_probe"
OUT="$HERE/results/$(date '+%Y%m%d-%H%M')-$NAME"
STATUS="$OUT/status.txt"
KEEPALIVE=""
CAFFEINATE=""

if [ "$(id -u)" -eq 0 ]; then
  echo "sudo 없이 실행해 주세요. (빌드는 사용자 권한으로 해요)"
  exit 1
fi
mkdir -p "$OUT" "$WORK"

status() { echo "$(date '+%H:%M:%S') $*" >> "$STATUS"; echo ""; echo "== $*"; }
fail() { status "❌ $*"; exit 1; }
cleanup() {
  [ -n "$KEEPALIVE" ] && kill "$KEEPALIVE" 2>/dev/null
  [ -n "$CAFFEINATE" ] && kill "$CAFFEINATE" 2>/dev/null
}
trap cleanup EXIT
trap 'status "중단됨"; exit 130' INT TERM
chime() { afplay /System/Library/Sounds/Glass.aiff > /dev/null 2>&1 & }
quit_app() {
  osascript -e "tell application id \"$APP_ID\" to quit" > /dev/null 2>&1
  for _ in $(seq 1 20); do pgrep -x MonitorTool > /dev/null || break; sleep 0.5; done
  if pgrep -x MonitorTool > /dev/null; then
    killall MonitorTool 2> /dev/null
    sleep 1
  fi
}

# 1분마다 본 %CPU가 10 이상이었던 다른 프로세스 (측정 잡음 확인용)
noise_summary() {
  awk '!/^#/ {
         cpu = $2 + 0; name = $0
         sub(/^ *[0-9]+ +[0-9.]+ +/, "", name); n = split(name, parts, "/"); name = parts[n]
         if (cpu >= 10) { if (cpu > top[name]) top[name] = cpu; count[name]++ }
       }
       END { found = 0
             for (k in top) { printf "- %s: 최대 %.0f%% (%d번)\n", k, top[k], count[k]; found = 1 }
             if (!found) print "- 없음" }' "$1"
}

# 측정 앞뒤의 프로세스 상태 (ps TIME으로 측정 도구의 CPU 시간을 대조하고, 잡음이 될 다른 프로세스를 봐요)
snapshot() {
  {
    echo "# $(date '+%Y-%m-%d %H:%M:%S')"
    echo "## MonitorTool 관련 프로세스 (TIME = 누적 CPU 시간)"
    ps -Ao pid,ppid,user,time,rss,command | grep -E "MonitorTool|powermetrics|chronod" \
      | grep -v -E "grep|rusage_probe|measure.sh"
    echo ""
    echo "## CPU를 많이 쓰는 프로세스 (ps %CPU)"
    ps -Ao pid,pcpu,rss,comm -r | head -n 15
    echo ""
    echo "## 전원"
    pmset -g batt | head -n 2
  } > "$1" 2>&1
}

# powermetrics 텍스트 출력의 평균 (시스템 전체라 다른 프로그램도 들어 있어요)
power_summary() {
  awk '
    /^CPU Power:/ { c += $3; cn++ }
    /^GPU Power:/ { g += $3; gn++ }
    /^ANE Power:/ { a += $3; an++ }
    /^Combined Power/ { v = $0; sub(/^[^:]*: */, "", v); split(v, p, " "); t += p[1]; tn++ }
    /^GPU HW active residency:/ { v = $0; sub(/^GPU HW active residency: */, "", v); sub(/%.*/, "", v); r += v; rn++ }
    END {
      printf "시스템 전체 (powermetrics 5초 표본 %d개 평균, 다른 프로그램 포함)\n", cn
      if (cn) printf "- CPU 전력 %.0f mW\n", c / cn
      if (gn) printf "- GPU 전력 %.0f mW, GPU 활성 %.1f%%\n", g / gn, (rn ? r / rn : 0)
      if (an) printf "- ANE 전력 %.0f mW\n", a / an
      if (tn) printf "- CPU+GPU+ANE %.0f mW\n", t / tn
    }' "$1"
}

measure() {
  local label="$1"
  local seconds="${2:-$MEASURE_SECONDS}"
  local dir="$OUT/$1"
  local count gpu probe_status noise
  mkdir -p "$dir"
  count=$(( seconds / 5 ))
  snapshot "$dir/before.txt"
  ( while true; do { echo "# $(date '+%H:%M:%S')"; ps -Ao pid,pcpu,comm -r | sed -n '2,7p'; } >> "$dir/noise.txt"; sleep 60; done ) &
  noise=$!
  sudo -n powermetrics --samplers cpu_power,gpu_power -i 5000 -n "$count" > "$dir/powermetrics.txt" 2>&1 &
  gpu=$!
  sudo -n "$PROBE" "$seconds" "$dir" > "$dir/probe.txt" 2>&1
  probe_status=$?
  wait "$gpu"
  kill "$noise" 2> /dev/null
  snapshot "$dir/after.txt"
  sudo -n chown -R "$(id -u):$(id -g)" "$dir"
  [ -f "$dir/samples.tsv" ] && gzip -f "$dir/samples.tsv"
  {
    cat "$dir/probe.txt"
    echo ""
    power_summary "$dir/powermetrics.txt"
    echo ""
    echo "다른 프로세스 (1분마다 본 %CPU가 10 이상)"
    noise_summary "$dir/noise.txt"
  } > "$dir/summary.txt"
  gzip -f "$dir/powermetrics.txt"
  [ "$probe_status" -eq 0 ] || fail "측정 도구 오류 ($label, $dir/probe.txt)"
}

{
  echo "이름: $NAME"
  echo "시작: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model)"
  echo "커밋: $(git -C "$ROOT" log --oneline -1)"
  echo "커밋 안 한 변경(추적 파일): $(git -C "$ROOT" status --porcelain --untracked-files=no | wc -l | tr -d ' ')개"
  git -C "$ROOT" status --porcelain --untracked-files=no | sed 's/^/  /'
  echo "측정: 상황마다 ${MEASURE_SECONDS}초 (열림은 ${OPEN_SETTLE}초, 닫힘은 ${CLOSED_SETTLE}초 기다린 뒤), 화면 꺼짐 ${SCREEN_OFF_SECONDS}초"
} > "$OUT/env.txt"

echo "관리자 암호를 물으면 입력해 주세요. (측정 도구와 powermetrics를 관리자 권한으로 실행해요)"
sudo -v || fail "관리자 권한을 받지 못함"
( while true; do sudo -n true 2> /dev/null; sleep 50; done ) &
KEEPALIVE=$!

status "1/5 측정 도구 컴파일·시험"
xcrun swiftc -O -swift-version 5 "$HERE/rusage_probe.swift" -o "$PROBE" > "$OUT/compile.txt" 2>&1 \
  || { cat "$OUT/compile.txt"; fail "측정 도구 컴파일 실패 (compile.txt)"; }
sudo -n "$PROBE" 2 "$OUT/selftest" > "$OUT/selftest.txt" 2>&1 \
  || { cat "$OUT/selftest.txt"; fail "측정 도구 시험 실패 (selftest.txt)"; }
sudo -n chown -R "$(id -u):$(id -g)" "$OUT/selftest"
cat "$OUT/selftest.txt"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
  status "2/5 빌드 건너뜀 (SKIP_BUILD=1), 설치된 앱 그대로"
else
  status "2/5 Release 빌드·설치 (Scripts/build-app.sh, 몇 분 걸려요)"
  bash "$ROOT/Scripts/build-app.sh" || fail "build-app.sh 실패"
  cp "$ROOT/build/App/build-app.log" "$OUT/build-app.log" 2> /dev/null
  status "설치 완료. macOS가 새 앱을 색인하는 동안 ${POST_INSTALL_SETTLE}초 기다려요"
  sleep "$POST_INSTALL_SETTLE"
fi

# 보조 프로그램을 새로 띄워요. 앱을 다시 설치해도 돌던 보조 프로그램은 예전 앱과 함께 휴지통 경로로 남아 있을 수 있어서,
# 앱을 끄고 보조 프로그램이 끝나기(연결이 다 끊긴 뒤 5초)를 기다렸다가 다시 켜요.
status "앱과 보조 프로그램 다시 켜기"
quit_app
for _ in $(seq 1 20); do pgrep -f "$HELPER_PATTERN" > /dev/null || break; sleep 1; done
pgrep -f "$HELPER_PATTERN" > /dev/null && echo "  (보조 프로그램이 20초 안에 끝나지 않아서 그대로 이어요)"
open "$APP"
for _ in $(seq 1 30); do pgrep -f "$HELPER_PATTERN" > /dev/null && break; sleep 1; done
HELPER_PID="$(pgrep -f "$HELPER_PATTERN" | head -n 1)"
if [ -n "$HELPER_PID" ]; then
  HELPER_PATH="$(sudo -n lsof -a -p "$HELPER_PID" -d txt -Fn 2> /dev/null | sed -n 's/^n//p' | grep 'MonitorToolHelper$' | head -n 1)"
  HELPER_NOTE="보조 프로그램 실행 중 (PID $HELPER_PID, ${HELPER_PATH:-경로 모름})"
  case "$HELPER_PATH" in
    "$APP"/*) ;;
    *) HELPER_NOTE="$HELPER_NOTE ⚠️ 설치된 앱 밖의 실행 파일" ;;
  esac
else
  HELPER_NOTE="⚠️ 보조 프로그램이 떠 있지 않아요. 설정 창 '보조 프로그램' 탭을 확인하고, 그대로 재려면 Enter, 멈추려면 Ctrl-C"
fi
echo "보조 프로그램: $HELPER_NOTE" >> "$OUT/env.txt"
echo "전원: $(pmset -g batt | head -n 1)" >> "$OUT/env.txt"

chime
echo ""
echo "▶ $HELPER_NOTE"
echo "▶ 패널을 열고(fn + Space 또는 메뉴 막대 아이콘) 오른쪽 위 고정 단추를 눌러 주세요."
echo "  위젯은 평소대로 두세요. 준비되면 이 터미널 창을 누르고 Enter. 그 뒤 약 25분 동안 Mac을 만지지 마세요."
read -r _
caffeinate -dims &
CAFFEINATE=$!

status "3/5 패널 열림·고정: ${OPEN_SETTLE}초 기다린 뒤 ${MEASURE_SECONDS}초 측정"
sleep "$OPEN_SETTLE"
measure open

status "4/5 패널 닫힘: 앱을 다시 켜고 ${CLOSED_SETTLE}초 기다린 뒤 ${MEASURE_SECONDS}초 측정"
quit_app
sleep 3
open "$APP"
sleep "$CLOSED_SETTLE"
measure closed

if [ "$SCREEN_OFF_SECONDS" -gt 0 ]; then
  # 화면만 끄고 Mac은 깨어 있게 해요. (caffeinate -d를 풀고 -i로 잠들지만 않게)
  status "화면 꺼짐: 화면을 끄고 30초 기다린 뒤 ${SCREEN_OFF_SECONDS}초 측정"
  [ -n "$CAFFEINATE" ] && kill "$CAFFEINATE" 2> /dev/null
  caffeinate -ims &
  CAFFEINATE=$!
  pmset displaysleepnow
  sleep 30
  measure screen-off "$SCREEN_OFF_SECONDS"
  caffeinate -u -t 2 > /dev/null 2>&1
fi

status "5/5 정리"
{
  cat "$OUT/env.txt"
  echo ""
  echo "## 패널 열림·고정"
  cat "$OUT/open/summary.txt"
  echo ""
  echo "## 패널 닫힘"
  cat "$OUT/closed/summary.txt"
  if [ -f "$OUT/screen-off/summary.txt" ]; then
    echo ""
    echo "## 화면 꺼짐 (패널 닫힘)"
    cat "$OUT/screen-off/summary.txt"
  fi
} > "$OUT/summary.txt"
status "끝"
chime
echo ""
cat "$OUT/summary.txt"
echo ""
echo "결과: $OUT/summary.txt"
echo "패널 고정을 평소에 쓰지 않으면 고정 단추를 다시 눌러 풀어 주세요."
