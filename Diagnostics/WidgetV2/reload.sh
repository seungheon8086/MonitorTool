#!/bin/bash
# 위젯이 예전 모습일 때: 빌드된 확장 시각과 실행 중인 확장을 확인하고, 위젯 관련 프로세스를 다시 시작해요.
# 결과는 Diagnostics/WidgetV2/reload.txt
cd "$(dirname "$0")" || exit 1
APP="$HOME/Library/Developer/Xcode/DerivedData/MonitorTool-hfbbmnptcqobsxbgskzjkyiosjtk/Build/Products/Debug/MonitorTool.app"
EXT="$APP/Contents/PlugIns/MonitorToolWidget.appex"
{
  echo "== 시각"; date
  echo "== 빌드된 확장"; ls -lT "$EXT/Contents/MacOS"
  echo "== 확장 안에 그래프 단추 글자가 남아 있는지 (있으면 예전 빌드)"
  strings "$EXT/Contents/MacOS/MonitorToolWidget.debug.dylib" | grep -c "chart.xyaxis.line"
  echo "== 실행 중인 확장"; ps -o pid,lstart,command -ax | grep -i "[M]onitorToolWidget"
  echo "== 등록 위치"; pluginkit -mAvvv -i com.seungheon.MonitorTool.widget 2>&1 | grep -E "Path|Timestamp"
} > reload.txt 2>&1
killall MonitorToolWidget chronod NotificationCenter 2>/dev/null
echo "끝: Diagnostics/WidgetV2/reload.txt"
