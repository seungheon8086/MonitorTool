# WidgetKitProbe: WidgetKit 위젯 진단

구형 Today 확장이 macOS 27에서 등록되지 않아([TodayWidgetProbe 결과](../TodayWidgetProbe/README.md)), 알림 센터 위젯은 **WidgetKit 위젯 안에서 버튼으로 요약 ↔ 상세 화면을 전환**하는 방식으로 정했습니다. 이 진단 앱은 그 방식이 이 Mac에서 실제로 되는지 확인합니다.

## 확인할 것

1. **위젯 안 화면 전환:** 위젯의 버튼(App Intent)을 누르면 같은 크기 안에서 요약 ↔ 상세(그래프)가 바뀌는지, 알림 센터가 닫히지 않는지
2. **앱과의 데이터 공유:** 앱이 App Group 공유 폴더에 쓴 값을 위젯이 읽는지 (개인 팀 서명으로 가능한지)
3. **실제 갱신 간격:** 앱이 5초마다 갱신을 요청할 때 위젯이 실제로 얼마나 자주 새 값을 보여주는지, 버튼을 누를 때 최신 값으로 바뀌는지

## 구성

- `ProbeHost/`: 5초마다 공유 폴더에 더미 스냅샷(`snapshot.json`)을 쓰고 `WidgetCenter.reloadAllTimelines()`를 부르는 앱. 메인 앱처럼 샌드박스 없음
- `ProbeWidget/`: 요약·상세 화면이 있는 WidgetKit 위젯(중간·큰 크기). 버튼은 `ToggleDetailIntent`(App Intent)를 실행
- `Shared/`: 두 타깃이 함께 쓰는 스냅샷 모델과 App Group 이름
- `*.entitlements`: App Group `$(TeamIdentifierPrefix)com.seungheon.WidgetKitProbe`. 위젯은 샌드박스 켬

## 실행 순서

1. `WidgetKitProbe.xcodeproj`를 엽니다. 서명 팀은 개인 팀으로 미리 지정돼 있습니다.
2. 상단 스킴이 **ProbeHost**인지 확인하고 ⌘R로 실행합니다. 창의 '쓴 횟수'가 5초마다 올라가면 정상입니다.
3. 알림 센터 맨 아래 **위젯 편집**에서 `MonitorTool WidgetKit Probe`를 찾아 중간 또는 큰 크기로 추가합니다.
4. 위젯의 '쓴 횟수'와 '위젯이 그린 시각'을 앱 창의 값과 비교하며 5~10분 지켜봅니다.
5. 위젯의 **상세 보기** 버튼을 눌러 그래프로 바뀌는지, **요약 보기**로 돌아오는지 확인합니다.

## 결과 기록

- 검증 기기: MacBookPro18,1 (M1 Pro), macOS 27.0.1, Xcode 27.1
- 결과: (검증 후 작성)
