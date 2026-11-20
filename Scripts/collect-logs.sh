#!/bin/bash
# 실사용 중 문제가 생기면 기록을 한곳에 모아요. 모은 폴더(build/logs/<시각>/)를 Claude가 읽어요.
# 앱·보조 프로그램 기록은 macOS 통합 기록에 공개로 남아 있어요(AppLog·HelperLog). 며칠 지나면 macOS가 지우니 문제를 본 날 모아 주세요.
#
# 사용법 (터미널, sudo 없이):
#   bash ~/Desktop/MonitorTool/MonitorTool/Scripts/collect-logs.sh        # 최근 1일
#   bash ~/Desktop/MonitorTool/MonitorTool/Scripts/collect-logs.sh 6h     # 기간 (log show --last 형식: 30m, 6h, 3d)
#
# 모으는 것
#  monitortool.log  앱·보조 프로그램 기록 (subsystem com.seungheon.MonitorTool*)
#  errors.log       MonitorTool·MonitorToolHelper·MonitorToolWidget 프로세스 안에서 난 시스템 오류·결함
#  system.log       다른 프로세스가 MonitorTool에 대해 남긴 기록 (launchd·위젯·권한 등) + 커널 추적 소유 기록(ktrace:)
#                   패널을 여닫을 때마다 상태 줄을 쏟아내는 runningboardd·MenuBarAgent·gamepolicyd 등은 오류만 남겨요
#                   (2026-11-21 첫 시험: 15분에 4,788줄 중 약 600줄이 이 셋)
#  power.log        잠자기·깨어남 (pmset -g log)
#  crash/           충돌·멈춤 보고서 (최근 14일, ~/Library/Logs/DiagnosticReports · /Library/Logs/DiagnosticReports)
#  info.txt         설치된 앱 버전·빌드 커밋·프로세스 상태·보조 프로그램 등록 상태

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPAN="${1:-1d}"
if ! [[ "$SPAN" =~ ^[0-9]+[smhd]$ ]]; then
  echo "기간 형식 오류: $SPAN (예: 30m, 6h, 1d)"
  exit 1
fi
OUT="$ROOT/build/logs/$(date '+%Y-%m-%d_%H%M%S')"
APP="/Applications/MonitorTool.app"
mkdir -p "$OUT/crash" || exit 1
echo "== MonitorTool 기록 모으기 (최근 $SPAN) → build/logs/$(basename "$OUT")"

echo "1/5 앱·보조 프로그램 기록"
log show --last "$SPAN" --style compact --info \
  --predicate 'subsystem BEGINSWITH "com.seungheon.MonitorTool"' > "$OUT/monitortool.log" 2>&1

echo "2/5 세 프로세스의 시스템 오류"
log show --last "$SPAN" --style compact \
  --predicate '(process == "MonitorTool" OR process == "MonitorToolHelper" OR process == "MonitorToolWidget") AND (messageType == error OR messageType == fault) AND NOT (subsystem BEGINSWITH "com.seungheon.MonitorTool")' \
  > "$OUT/errors.log" 2>&1

echo "3/5 다른 프로세스의 MonitorTool 기록 (조금 걸려요)"
log show --last "$SPAN" --style compact \
  --predicate '(eventMessage CONTAINS[c] "com.seungheon.MonitorTool" OR eventMessage CONTAINS "ktrace:") AND NOT (subsystem BEGINSWITH "com.seungheon.MonitorTool") AND NOT (process BEGINSWITH "MonitorTool") AND (messageType == error OR messageType == fault OR NOT (process == "runningboardd" OR process == "MenuBarAgent" OR process == "gamepolicyd" OR process == "intelligencecontextd" OR process == "suggestd" OR process == "linkd" OR process == "Siri" OR process == "siriactionsd" OR process == "lsd" OR process == "pkd" OR process == "trustd" OR process == "dmd" OR process == "distnoted" OR process == "containermanagerd"))' \
  > "$OUT/system.log" 2>&1

echo "4/5 잠자기·깨어남"
pmset -g log 2>/dev/null | grep -E "^[0-9-]+ [0-9:]+ [+-][0-9]+ +(Sleep|Wake|DarkWake)[[:space:]]" | tail -n 400 > "$OUT/power.log"

echo "5/5 충돌 보고서·상태"
for dir in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
  [ -d "$dir" ] || continue
  find "$dir" -maxdepth 2 -type f -name 'MonitorTool*' -mtime -14 -exec cp -p {} "$OUT/crash/" \; 2>> "$OUT/crash/copy-errors.txt"
done
[ -s "$OUT/crash/copy-errors.txt" ] || rm -f "$OUT/crash/copy-errors.txt"

{
  echo "모은 때: $(date '+%Y-%m-%d %H:%M:%S %z') · 기간 $SPAN"
  echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · 켜진 지: $(uptime | sed 's/^ *//')"
  echo
  echo "== 설치된 앱 ($APP)"
  if [ -d "$APP" ]; then
    echo "버전: $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null) ($(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null))"
    echo "앱 실행 파일: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$APP/Contents/MacOS/MonitorTool" 2>/dev/null)"
    echo "보조 프로그램 실행 파일: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$APP/Contents/MacOS/MonitorToolHelper" 2>/dev/null)"
  else
    echo "없음"
  fi
  echo "마지막 build-app.sh: $(head -n 2 "$ROOT/build/App/build-app.log" 2>/dev/null | tr '\n' ' ')"
  echo "저장소 지금: $(git -C "$ROOT" log --oneline -1 2>/dev/null)"
  git -C "$ROOT" status --short --untracked-files=no 2>/dev/null | sed 's/^/  /'
  echo
  echo "== MonitorTool 프로세스"
  ps -axo pid,user,%cpu,%mem,rss,etime,command | awk 'NR == 1 || /MonitorTool|powermetrics/' | grep -v -E 'awk|collect-logs'
  echo
  echo "== CPU 많이 쓰는 프로세스 (위 10개)"
  ps -axro pid,%cpu,rss,comm | head -n 11
  echo
  echo "== 보조 프로그램 등록 (launchctl print, 앞부분)"
  launchctl print system/com.seungheon.MonitorTool.helper 2>&1 | head -n 30
  echo
  echo "== 전원"
  pmset -g batt 2>&1
  echo
  echo "== 모은 파일 (줄 수)"
  wc -l "$OUT"/*.log | sed 's|'"$OUT"'/||'
  echo "충돌 보고서: $(find "$OUT/crash" -type f | wc -l | tr -d ' ')개"
} > "$OUT/info.txt" 2>&1

echo
echo "끝. 모은 곳: build/logs/$(basename "$OUT")"
grep -E "충돌 보고서|\.log" "$OUT/info.txt" | sed 's/^/  /'
