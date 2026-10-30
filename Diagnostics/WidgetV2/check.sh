#!/bin/bash
# 위젯 2판이 알림 센터 목록에 안 보일 때: 빌드된 확장·서명·등록 상태를 모으고, 확장을 다시 등록해요.
# 결과는 Diagnostics/WidgetV2/check.txt
cd "$(dirname "$0")" || exit 1
APP="$HOME/Library/Developer/Xcode/DerivedData/MonitorTool-hfbbmnptcqobsxbgskzjkyiosjtk/Build/Products/Debug/MonitorTool.app"
EXT="$APP/Contents/PlugIns/MonitorToolWidget.appex"
{
  echo "== 시각"; date
  echo "== 확장 폴더"; ls -la "$EXT/Contents" "$EXT/Contents/MacOS"
  echo "== 확장 Info.plist"; plutil -p "$EXT/Contents/Info.plist"
  echo "== 확장 서명·권한"; codesign -dv --entitlements - "$EXT" 2>&1
  echo "== 앱 서명·권한"; codesign -dv --entitlements - "$APP" 2>&1
  echo "== 등록 전 pluginkit"; pluginkit -mAvvv -p com.apple.widgetkit-extension 2>&1 | grep -i -B1 -A6 monitortool
  echo "== 다시 등록"; pluginkit -a "$EXT" 2>&1; echo "종료 코드 $?"
  sleep 2
  echo "== 등록 후 pluginkit"; pluginkit -mAvvv -p com.apple.widgetkit-extension 2>&1 | grep -i -B1 -A6 monitortool
  echo "== 최근 10분 로그 (MonitorToolWidget)"
  log show --last 10m --style compact --predicate 'eventMessage CONTAINS[c] "MonitorToolWidget" OR process == "MonitorToolWidget"' 2>&1 | tail -60
} > check.txt 2>&1
killall chronod 2>/dev/null
echo "끝: Diagnostics/WidgetV2/check.txt"
