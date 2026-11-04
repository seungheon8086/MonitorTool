#!/bin/bash
# MonitorTool을 Release로 빌드해서 응용 프로그램 폴더(/Applications)에 설치해요.
# Xcode의 Archive는 쓰지 않아요. (Archive 안의 예전 위젯 확장이 위젯 목록을 가린 적이 있어서)
#
# 사용법 (터미널, sudo 없이):
#   bash ~/Desktop/MonitorTool/MonitorTool/Scripts/build-app.sh
#
# 하는 일
#  1. Release 빌드 (개인 팀 자동 서명, build/App 아래)
#  2. 서명·구성 확인 (보조 프로그램·LaunchDaemon plist·위젯 확장이 들어 있는지)
#  3. 실행 중인 MonitorTool 종료 → 보조 프로그램이 끝나기를 기다림 → 예전 /Applications/MonitorTool.app은 휴지통으로 → 새 앱 복사
#  4. 위젯 등록 정리(lsregister), 등록 위치 출력, 새 앱 실행
# 기록: build/App/build-app.log

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

OUT="$ROOT/build/App"
DERIVED="$OUT/DerivedData"
LOG="$OUT/build-app.log"
BUILT="$DERIVED/Build/Products/Release/MonitorTool.app"
DEST="/Applications/MonitorTool.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

mkdir -p "$OUT"
: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }
fail() { log "❌ $*"; log "자세한 기록: $LOG"; exit 1; }

log "== MonitorTool .app 만들기 ($(date '+%Y-%m-%d %H:%M:%S'))"
log "커밋: $(git -C "$ROOT" log --oneline -1 2>/dev/null)"
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  log "⚠️ 커밋하지 않은 변경이 있어요. 그 상태 그대로 빌드해요."
fi

log ""
log "== 1/4 Release 빌드 (처음에는 몇 분 걸려요)"
xcodebuild -project MonitorTool.xcodeproj -scheme MonitorTool -configuration Release \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates build >> "$LOG" 2>&1
status=$?
if [ $status -ne 0 ]; then
  log "빌드 오류 (마지막 줄들):"
  grep -E "error:|warning: .*signing|BUILD FAILED" "$LOG" | tail -n 20 | sed 's/^/  /'
  fail "Release 빌드 실패 (xcodebuild $status)"
fi
[ -d "$BUILT" ] || fail "빌드는 끝났는데 앱을 찾지 못함: $BUILT"
log "✅ 빌드 완료: $BUILT"

log ""
log "== 2/4 서명·구성 확인"
for part in "Contents/MacOS/MonitorTool" "Contents/MacOS/MonitorToolHelper" \
            "Contents/Library/LaunchDaemons/com.seungheon.MonitorTool.helper.plist" \
            "Contents/PlugIns/MonitorToolWidget.appex"; do
  [ -e "$BUILT/$part" ] || fail "앱 안에 없음: $part"
  log "  있음: $part"
done
codesign --verify --deep --strict "$BUILT" >> "$LOG" 2>&1 || fail "서명 확인 실패 (codesign --verify)"
log "  서명: $(codesign -dv "$BUILT" 2>&1 | grep -E '^TeamIdentifier=' | tr '\n' ' ')$(codesign -dv "$BUILT" 2>&1 | grep -E '^Authority=' | head -n 1)"
log "  버전: $(defaults read "$BUILT/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null) ($(defaults read "$BUILT/Contents/Info.plist" CFBundleVersion 2>/dev/null))"

log ""
log "== 3/4 /Applications에 설치"
if pgrep -x MonitorTool > /dev/null; then
  log "  실행 중인 MonitorTool을 종료해요. (Xcode에서 실행 중이면 Xcode의 ■ 정지가 함께 일어나요)"
  osascript -e 'tell application id "com.seungheon.MonitorTool" to quit' >> "$LOG" 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MonitorTool > /dev/null || break; sleep 0.5; done
  pgrep -x MonitorTool > /dev/null && { killall MonitorTool 2>/dev/null; sleep 1; }
fi
# 앱이 끝나면 보조 프로그램도 연결이 끊긴 뒤 5초 안에 끝나요. 그 전에 앱을 바꾸면, 돌던 보조 프로그램이
# 예전 앱과 함께 휴지통 경로로 남아 예전 파일로 계속 돌아요. (2026-11-04 자원 사용 측정에서 겪음)
# launchd가 BundleProgram 상대 경로로 띄워서 명령줄이 'Contents/MacOS/MonitorToolHelper'예요.
if pgrep -f "Contents/MacOS/MonitorToolHelper" > /dev/null; then
  log "  보조 프로그램이 끝나기를 기다려요."
  for _ in $(seq 1 30); do pgrep -f "Contents/MacOS/MonitorToolHelper" > /dev/null || break; sleep 0.5; done
  pgrep -f "Contents/MacOS/MonitorToolHelper" > /dev/null && log "  ⚠️ 보조 프로그램이 15초 안에 끝나지 않았어요. 그대로 바꿔요."
fi
if [ -e "$DEST" ]; then
  TRASHED="$HOME/.Trash/MonitorTool $(date '+%Y-%m-%d %H.%M.%S').app"
  mv "$DEST" "$TRASHED" || fail "예전 앱을 휴지통으로 옮기지 못함 ($DEST)"
  log "  예전 앱은 휴지통으로: $(basename "$TRASHED")"
fi
ditto "$BUILT" "$DEST" || fail "복사 실패 ($DEST)"
codesign --verify --deep --strict "$DEST" >> "$LOG" 2>&1 || fail "설치한 앱의 서명 확인 실패"
log "✅ 설치: $DEST"

log ""
log "== 4/4 위젯 등록 정리와 실행"
"$LSREGISTER" -f "$DEST" >> "$LOG" 2>&1
pluginkit -a "$DEST/Contents/PlugIns/MonitorToolWidget.appex" >> "$LOG" 2>&1
log "  위젯 확장 등록 위치:"
pluginkit -mAvvv -i com.seungheon.MonitorTool.widget 2>&1 | grep -E "Path" | sed 's/^ */    /' | tee -a "$LOG"
open "$DEST"
log ""
log "끝. 처음 실행이면 설정 > 보조 프로그램에서 다시 허용해 주세요."
log "위젯이 예전 모습이면: 위젯 제거 → 다시 추가 (또는 Diagnostics/WidgetV2/reload.sh)"
