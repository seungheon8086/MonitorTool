# TodayWidgetProbe: 알림 센터 구형 위젯 진단

[설계 문서](../../docs/PROJECT_DESIGN.md) 7장 1번 항목(구형 Today 확장의 실제 동작 확인)을 위한 작은 진단 앱입니다.
더미 수치와 펼치기 버튼만 있는 구형 Today 확장(`NCWidgetProviding`)을 앱에 넣고, 현재 macOS의 알림 센터가 이 확장을 등록·표시하는지, 버튼을 누르면 위젯 높이가 늘어나는지 확인합니다.

## 구성

- `ProbeHost/`: 확장을 담는 앱. 실행하면 확인 순서를 보여줍니다.
- `ProbeWidget/`: 구형 Today 확장. 버튼을 누르면 `preferredContentSize` 높이를 90 ↔ 260pt로 바꿉니다.
- `ProbeWidget-Info.plist`: 확장 지점 `com.apple.widget-extension` 선언

메인 앱(MonitorTool)과는 별개 프로젝트라, 결과와 상관없이 메인 앱에 영향을 주지 않습니다.

## 실행 순서

1. `TodayWidgetProbe.xcodeproj`를 엽니다.
2. 두 타깃(ProbeHost, ProbeWidget)의 **Signing & Capabilities → Team**을 개인 팀(Personal Team)으로 고릅니다. 서명 문제로 확장이 등록되지 않는 경우를 배제하기 위해서입니다.
3. 상단 스킴을 **ProbeHost**로 두고 ⌘R로 실행합니다.
4. 터미널에서 등록 여부를 확인합니다.
   ```sh
   pluginkit -mAvvv -p com.apple.widget-extension
   ```
5. 알림 센터를 열고 맨 아래 **위젯 편집**에서 `MonitorTool Probe`를 찾습니다.
6. 보이면 추가한 뒤 **펼치기**를 눌러 높이가 늘어나는지, 아래 위젯이 밀려나는지 확인합니다.
7. 확장이 실제로 불렸는지 로그로 확인합니다.
   ```sh
   log show --last 10m --predicate 'eventMessage CONTAINS "TodayWidgetProbe"' --info
   ```

## 판정 기준

| 관찰 | 의미 |
|---|---|
| 앱 안에 확장이 없거나 선언·서명이 잘못됨 | 진단 앱 문제. 고쳐서 다시 확인 |
| 구성·서명이 정상인데 pluginkit에 등록되지 않음 | 현재 OS가 구형 확장 지점을 받지 않음 → 요구사항 미충족 |
| 등록됐지만 위젯 편집 목록에 없음 | OS가 등록은 하지만 표시하지 않음 → 요구사항 미충족 |
| 위젯은 보이지만 높이가 바뀌지 않음 | 표시는 되지만 펼침은 미지원 |
| 높이가 늘고 아래 위젯이 재배치됨 | 요구사항 충족 가능 |

## 결과 기록 (2026-10-22)

- 검증 기기: MacBookPro18,1 (M1 Pro), macOS 27.0.1, Xcode 27.1
- **판정: 미지원. macOS 27.0.1은 구형 Today 확장을 등록하지 않는다.**

| 확인 항목 | 결과 |
|---|---|
| 빌드된 앱 안의 확장 | `ProbeHost.app/Contents/PlugIns/ProbeWidget.appex` 있음 |
| 확장 선언 | `CFBundlePackageType = XPC!`, `NSExtensionPointIdentifier = com.apple.widget-extension`, `NSExtensionPrincipalClass = TodayViewController` |
| 서명 | Apple Development 인증서, 개인 팀으로 서명 |
| 샌드박스 | `com.apple.security.app-sandbox` 있음 |
| 시스템 전체의 구형 위젯 등록 (`pluginkit -mAvvv -p com.apple.widget-extension`) | 없음 (`no matches`) |
| 확장 경로·앱 경로로 직접 등록 (`pluginkit -a`) 후 조회 | 등록되지 않음 |
| 알림 센터 위젯 편집 목록 | 나타나지 않음 |
| 확장 실행 로그 (`[TodayWidgetProbe]`) | 없음. 알림 센터가 한 번도 불러오지 않음 |
| 등록 담당 프로세스(pkd) 로그 | 관련 기록 없음 |
| 비교: WidgetKit 위젯 (`com.apple.widgetkit-extension`) | 같은 Mac에 정상 등록돼 있음 (Outlook, Teams, 시스템 설정 위젯 등) |

확장의 구성과 서명이 정상이고 같은 Mac에서 WidgetKit 위젯은 정상 등록되는데, 구형 확장 지점의 확장만 직접 등록해도 받아들여지지 않았다. 따라서 알림 센터 안에서 클릭으로 위젯 높이를 늘리는 동작은 구형 Today 확장으로 구현할 수 없다. WidgetKit은 크기 계열이 고정이라 같은 동작을 제공하지 않는다. Monit 개발사가 Big Sur 이후 예전 위젯을 옮길 수 없었다고 밝힌 내용과도 일치한다.
