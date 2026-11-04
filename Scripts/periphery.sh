#!/bin/bash
# 안 쓰는 코드를 Periphery로 찾아요. (설치: brew install periphery)
#
# 사용법 (터미널, sudo 없이, Xcode는 닫고):
#   bash ~/Desktop/MonitorTool/MonitorTool/Scripts/periphery.sh
#
# MonitorTool 스킴(앱·보조 프로그램·위젯 확장)을 서명 없이 Debug로 한 번 빌드하고, 그 색인으로 검사해요.
# 결과: build/periphery.txt
# 일부러 남긴 것(C 구조체 배치 칸, 붙잡아 두는 객체, #Preview에서만 쓰는 미리보기 값)은 코드에
# '// periphery:ignore'로 표시해 뒀어요. 그래서 경고가 0개면 안 쓰는 코드가 없는 거예요.
# (Periphery는 #Preview 안에서 쓰는 것을 보지 못해서, 미리보기 값은 표시가 필요해요)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
command -v periphery > /dev/null || { echo "periphery가 없어요. 먼저 brew install periphery"; exit 1; }
mkdir -p build
echo "검사 중 (프로젝트를 한 번 빌드해서 몇 분 걸려요)"
periphery scan --project MonitorTool.xcodeproj --schemes MonitorTool --retain-objc-accessible \
  --format xcode -- CODE_SIGNING_ALLOWED=NO > build/periphery.txt 2>&1
status=$?
count=$(grep -c ': warning:' build/periphery.txt)
echo "경고 ${count}개 (결과 코드 ${status}), 결과: build/periphery.txt"
grep ': warning:' build/periphery.txt | sed "s#^$ROOT/##"
grep -E ': error:|BUILD FAILED' build/periphery.txt | head -n 20
exit "$status"
