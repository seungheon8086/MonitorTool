# MonitorTool

macOS 메뉴 막대에 상주하는 개인용 시스템 모니터링 앱입니다. 단축키나 메뉴 막대 아이콘으로 화면 오른쪽에 실시간 패널을 꺼내 보고, 알림 센터에서도 같은 수치를 확인하는 것을 목표로 합니다. [Monit](https://mmonit.com/widget/)의 빠르게 확인하는 사용 경험을 참고했습니다.

> 개발 중입니다. 설계는 [docs/PROJECT_DESIGN.md](docs/PROJECT_DESIGN.md)에 있고, 단계별 작업 과정을 커밋 기록으로 남기고 있습니다.

## 보여줄 정보

| 항목 | 기본 화면 | 펼치면 |
|---|---|---|
| CPU | E-core·P-core 사용률, CPU 전력 W | E/P 사용률·전력 그래프, 코어별 정보 |
| ANE (Neural Engine) | 사용률 %, 전력 W | 사용률·전력 그래프, 측정 범위 설명 |
| GPU | 사용률, GPU 전력 W | 사용률·전력 그래프 |
| RAM | 사용량/전체, 사용률 | 사용량 그래프, 메모리 압력, 압축, 스왑 |
| 온도·팬 | CPU·GPU 최고 온도, 팬별 RPM | 센서별 온도, 팬별 RPM 그래프 |
| 배터리 | 잔량, 충전/방전 상태, 순전력 W, 예상 시간 | 순전력 그래프, 성능 상태, 사이클 수 |
| 네트워크 | 업로드·다운로드 속도, 오늘 누적 | 그래프, 오늘·이번 실행 누적, 인터페이스별 수치 |

측정 전이거나 읽지 못한 값은 0으로 채우지 않고 상태(준비 중·미지원·권한 필요·오류·오래됨)로 표시합니다.

## 화면

- **실시간 패널**: 메뉴 막대 아이콘이나 단축키(⌃⌥M)로 화면 오른쪽에서 꺼냅니다. 수치를 누르면 그 행 아래에 그래프와 상세 정보가 펼쳐집니다.
- **알림 센터 위젯**: 핵심 수치를 보여주고, 버튼을 누르면 같은 크기 안에서 상세(그래프) 화면으로 바뀝니다. 원래는 누르면 위젯 높이가 늘어나는 방식을 원했지만, 이를 위한 구형 Today 확장이 macOS 27에서 등록되지 않는 것을 [진단 앱](Diagnostics/TodayWidgetProbe)으로 확인하고 이 방식으로 바꿨습니다.

## 설계 원칙

- 수집은 메인 앱 한 곳에서 하고, 패널과 위젯은 같은 데이터를 봅니다.
- 관리자 권한이 필요한 읽기(전력, ANE 등)는 앱 전체가 아니라 최소한의 보조 프로세스로 분리합니다.
- 온도·팬 센서(SMC)와 시스템 정보를 읽기 위해 App Sandbox를 끕니다. 개인용이라 App Store 배포는 고려하지 않습니다.

## 진행 상황

- [x] 프로젝트 설정 (macOS 전용, App Sandbox 해제)
- [x] 실시간 패널 뼈대: 메뉴 막대 아이콘, ⌃⌥M 단축키, 오른쪽 슬라이드 패널(Liquid Glass)
- [x] 설계 검토안 ([docs/PROJECT_DESIGN.md](docs/PROJECT_DESIGN.md))
- [ ] 기술 검증
  - [x] 알림 센터 구형 Today 확장의 표시·높이 변경 → macOS 27 미지원 확인 ([진단 앱](Diagnostics/TodayWidgetProbe))
  - [x] WidgetKit 위젯: 위젯 안 화면 전환, 앱과의 데이터 공유, 앱이 뒤에 있을 때의 갱신 ([진단 앱](Diagnostics/WidgetKitProbe))
  - [ ] CPU/GPU/ANE 전력과 ANE 사용률
  - [ ] E/P 코어 사용률의 정의
  - [ ] 온도 센서·팬 RPM 읽기
- [ ] 화면 구현: 패널과 위젯의 접기/펼치기, 상태 표시, 최근 그래프
- [ ] 네트워크 기록: 오늘·이번 실행 누적, 저장과 복구
- [ ] 통합과 실사용 점검
- [ ] 선택 단계: 메뉴 막대 수치, 팬 RPM 조절(패널 전용)

## 폴더 구조

```
MonitorTool/      앱 코드
  App/            시작점, AppDelegate
  MenuBar/        메뉴 막대 아이콘
  Panel/          사이드 패널 창과 화면
  Support/        전역 단축키
Diagnostics/      기술 검증용 진단 앱
docs/             설계 문서
```

## 개발 환경

- MacBook Pro (M1 Pro), macOS 27
- Xcode 27, Swift, SwiftUI + AppKit
- 외부 라이브러리 없음

## 참고

- [Monit Widget](https://mmonit.com/widget/): 슬라이드 패널 UI
- [Stats](https://github.com/exelban/stats): macOS 시스템 정보를 읽는 방식 (MIT)
