# 알림 센터 위젯 2판 설계 (Widget_ver2)

작성 2026-10-30. 첫 구현(`widget-v1` 브랜치, 지금은 `archive/widget-v1` 태그)은 사용자 결정으로 폐기하고 처음부터 다시 만든다.
기준 결정은 `PROJECT_DESIGN.md` 2장(큰·중간 크기, 같은 항목 색, 오래됨 표시)을 따른다. 같은 크기 안 요약 ↔ 상세 전환은 2026-10-30 사용자 결정으로 그래프 전용 위젯으로 바꾼다(2장).

## 1. 목표

- 패널과 같은 모양: 같은 카드(바탕 `primary 4.5%`, 모서리는 위젯 바깥 모서리와 동심 — `ContainerRelativeShape`), 같은 글꼴 크기, 같은 막대·상태 표시, 같은 항목 색
- 바깥 Liquid Glass는 macOS가 정한다
  - 첫 구현의 실험(`widget-v1`의 `Diagnostics/WidgetGlassProbe/RESULTS.md`)에서 앱이 위젯 하나만 유리 배경으로 바꾸는 공개 방법은 찾지 못함
  - 시스템 설정 > 모양 > 아이콘 및 위젯 스타일을 '투명'으로 하면 유리 배경이 됨
  - 그래서 위젯은 시스템 배경(`containerBackground`, 제거 가능) 위에 패널과 같은 반투명 카드만 그린다. 투명·색조 스타일에서도 카드와 글이 그대로 읽히게 한다
- 단순하게: 위젯 종류 하나, 크기 둘, 기록 DB 없음, 새로고침 설정 없음

## 2. 화면

위젯 종류 `MonitorToolWidget` 하나, 크기는 중간·큰. 요약만 보여준다.
(2026-10-30 사용자 결정: 위젯 안 그래프 전환 단추는 너무 작아 누르기 어려워 뺌. 그래프는 다음 단계에서 그래프만 띄우는 중간·작은 위젯을 따로 만든다)

맨 위 줄: `MonitorTool` · 측정 시각 · 상태 배지(정상이면 비움)

| 크기 | 요약 |
|---|---|
| 중간 | 패널 맨 위 카드(CPU E·P / GPU 사용률 / ANE 사용 중·쉬는 중, 맨 아래 전력 W) + 한 줄 칩(메모리 % · 배터리 순전력 · ↓ 속도 · ↑ 속도). 배터리 잔량은 메뉴 막대에서도 보여서 뺌(2026-10-30 사용자 요청) |
| 큰 | 맨 위 카드 + 메모리 카드(사용량·막대·%, 제목 줄에 TRAFFIC(DRAM 대역폭)·압력) + 온도·팬 카드와 네트워크 카드 나란히(↓·↑ 줄마다 속도와 오늘 누적, 기준 날짜) + 긴 배터리 카드(잔량 막대, 충전·방전과 남은 시간, 순전력). 네트워크·배터리 자리는 2026-10-30 사용자 요청으로 바꿈 |

### 그래프 위젯 (작은 크기, 항목마다 하나 — 2026-10-30 사용자 결정)

| 위젯 (종류) | 선 | 지금 값 |
|---|---|---|
| MonitorTool CPU·GPU 사용률 (`MonitorToolGraph.usage`) | P 진하게, E 연한 점선, GPU (0–100%) | P · E · GPU % |
| MonitorTool 전력 (`.power`) | CPU · GPU · ANE (값에 맞춘 축, 최소 1 W) | W |
| MonitorTool 온도 (`.temperature`) | CPU 최고 진하게, GPU 최고 연한 점선 (0–110 °C) | °C |
| MonitorTool 네트워크 (`.network`) | ↓ 진하게, ↑ 연한 점선 (최소 10 KB/s) | 속도 |
| MonitorTool 팬 (`.fan`) | 오른쪽 진하게, 왼쪽 연한 점선 (최소 2,000 RPM) | RPM · 정지 |
| MonitorTool 배터리 순전력 (`.battery`) | 0을 가운데 두고 + 충전 · − 방전 (최소 ±5 W) | ±W |

- 한 장 구성: 제목 · '10분' · 상태 배지 / 선마다 지금 값 / 꺾은선 / 측정 시각
- 왼쪽 눈금: 위·가운데·아래 숫자(단위 포함). 축 맨 위는 고정값이거나 값에 맞춘 1·2·2.5·5 × 10ⁿ (팬·배터리는 2026-10-30 사용자 요청으로 추가, 눈금도 같은 요청)
- 재는 간격이 10초보다 긴 계열(배터리 약 30초)은 가장 느린 수집 간격의 2.5배 안의 빈 칸을 앞 값으로 이음
- 10초 칸 60개(10분). 값이 없는 칸은 비우고 0으로 잇지 않음
- 앱은 저장 뒤 `reloadAllTimelines()`로 모든 위젯을 한 번에 갱신

## 3. 값 상태

- 값 하나하나는 패널과 같은 상태 표시(준비 중·권한 필요·측정 불가·꺼짐·읽지 못함·오래됨)
- 위젯 전체 상태는 맨 위 줄 배지
  - 오래됨: 마지막 저장 뒤 45초 넘음 → '오래됨', 내용 흐리게(45%)
  - 잠자기: 앱이 잠들기 직전에 남긴 표시 → '잠자기'
  - 앱 꺼짐: 앱이 끝날 때 남긴 표시 → '앱 꺼짐'
  - 기록 없음: 공유 파일 없음 → '앱 꺼짐 · 기록 없음'
- 시각은 측정 시각(`takenAt`). 네트워크 오늘 누적은 기준 날짜가 오늘이 아니면 '오늘' 대신 날짜

## 4. 데이터 공유

- 수집은 앱 한 곳. 위젯은 공유 파일만 읽음
- App Group `47C8XKJT3X.com.seungheon.MonitorTool`(개인 팀 접두어), 파일 `Library/Application Support/widget-v2.json` 하나
- 내용(`WidgetPayload`, 판 번호 1): 저장 시각, 앱 상태(동작·잠자기·꺼짐), `MonitorSnapshot`, 항목 색, 그래프 계열 13개(E·P·GPU 사용률, CPU·GPU·ANE 전력, CPU·GPU 온도, ↓·↑ 속도, 팬 2개, 배터리 순전력) × 60칸
- 쓰는 때(`WidgetPublisher`): 값이 바뀌면 10초에 한 번까지, 색을 바꿀 때, 잠들기 직전, 앱이 끝날 때. 쓰고 나서 `WidgetCenter.reloadAllTimelines()`
- 원자적 쓰기(`.atomic`). 크기 약 10 KB
- 위젯 타임라인: 지금 항목 + 45초 뒤 '오래됨' 항목, 정책 `.never`(새 값은 앱이 갱신 요청)

## 5. 코드 위치

- `WidgetShared/`(앱·위젯 공용 동기화 폴더): `WidgetPayload.swift`(형식·파일 위치·읽기·쓰기)
- 위젯이 함께 컴파일하는 앱 파일(참조): `Model/ValueState.swift`, `Model/MonitorSnapshot.swift`, `Model/FanName.swift`, `Appearance/MonitorItem.swift`, `Appearance/ItemColor.swift`, `Support/ValueFormat.swift`
- 앱: `MonitorTool/Widget/WidgetPublisher.swift`, `MonitorStore.onUpdate`, `AppearanceSettings.onChange`
- 위젯 확장 `MonitorToolWidget/`: 묶음·타임라인·화면·조각
- 프로젝트: 위젯 타깃(번들 ID `com.seungheon.MonitorTool.widget`, 샌드박스, App Group), 앱에 App Group 권한과 'Embed Foundation Extensions' 단계
