#!/bin/bash
# 예전(위젯 1판) Xcode 보관본(.xcarchive) 안의 위젯 확장을 macOS가 대신 실행하고 있어서,
# 보관본을 등록에서 빼고 압축 사본을 남긴 뒤 휴지통으로 옮겨요. 결과는 fix-archive.txt
cd "$(dirname "$0")" || exit 1
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BACKUP="$HOME/Desktop/MonitorTool/archive-backup"
mkdir -p "$BACKUP"
{
  echo "== 시각"; date
  find "$HOME/Library/Developer/Xcode/Archives" -maxdepth 2 -name 'MonitorTool*.xcarchive' -print0 |
  while IFS= read -r -d '' archive; do
    echo "== 보관본: $archive"
    app="$archive/Products/Applications/MonitorTool.app"
    [ -d "$app" ] && "$LSREG" -u "$app" && echo "등록 해제"
    name="$(basename "$archive" .xcarchive)"
    ditto -c -k --keepParent "$archive" "$BACKUP/$name.zip" && echo "압축 사본: $BACKUP/$name.zip"
    mv "$archive" "$HOME/.Trash/" && echo "휴지통으로 옮김"
  done
  echo "== 지금 빌드 다시 등록"
  APP="$HOME/Library/Developer/Xcode/DerivedData/MonitorTool-hfbbmnptcqobsxbgskzjkyiosjtk/Build/Products/Debug/MonitorTool.app"
  "$LSREG" -f "$APP" && echo "앱 등록"
  pluginkit -a "$APP/Contents/PlugIns/MonitorToolWidget.appex"; echo "확장 등록 종료 코드 $?"
} > fix-archive.txt 2>&1
killall chronod 2>/dev/null
sleep 3
log show --last 30s --style compact --predicate 'process == "chronod" AND eventMessage CONTAINS "MonitorToolWidget.appex"' 2>&1 | tail -5 | cut -c1-600 >> fix-archive.txt
echo "끝: Diagnostics/WidgetV2/fix-archive.txt"
