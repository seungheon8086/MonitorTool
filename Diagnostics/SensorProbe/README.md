# SensorProbe: 온도·팬·전력 센서 읽기 진단

[설계 문서](../../docs/PROJECT_DESIGN.md) 7장 5번 항목(온도·팬을 읽기만 하는 진단)을 확인합니다. 값을 바꾸는 명령은 보내지 않습니다.

## 확인할 것

1. 관리자 권한 없이 SMC 키와 HID 온도 센서를 읽을 수 있는지, 어떤 키·센서가 있고 형식(단위)은 무엇인지
2. 어느 온도 센서가 E코어·P코어·GPU·ANE 부하에 반응하는지 (대표 온도 'CPU 최고'·'GPU 최고'에 쓸 센서 고르기)
3. 팬 개수, 실제 RPM, 최소·최대·목표 RPM, 모드 키, 그리고 0 RPM과 읽기 실패의 구분
4. SMC 전력 키(P…) 중 powermetrics의 CPU 전력과 같이 움직이는 키가 있는지 (관리자 권한 없이 CPU 전력을 읽을 다른 길)
5. ANE 드라이버(IORegistry) 속성 중 ANE 사용률로 쓸 만한 값이 있는지 (가만히일 때와 ANE 부하 중 비교)

## 구성

- `sensor_probe.swift`: 관리자 권한 없이 SMC(AppleSMC의 읽기 명령만 사용)와 HID 온도 센서(IOHIDEventSystemClient)를 읽는 진단 도구. `list`(전체 목록), `sample`(T·F·P 키와 HID 온도를 1초마다 기록), `ane-ioreg`(ANE 관련 IORegistry 속성 저장). SMC 구조체 배치는 [Stats](https://github.com/exelban/stats)(MIT)의 방식을 참고
- `cpu_burn.swift`: 계산 부하 도구. QoS가 background인 스레드는 E코어에서만 돌고, userInteractive 스레드는 P코어를 먼저 써요
- `../PowerProbe/ane_load.swift`: GPU·ANE 부하에 다시 써요
- `measure.sh`: 아래 순서로 기록해요. 단계마다 powermetrics(관리자 권한)도 함께 기록해서 비교해요
- `results/`: 결과 원본

| 단계 | 부하 | 시간 |
|---|---|---|
| A | 없음 | 20초 |
| B | E코어 (background 스레드 4개) | 25초 |
| C | P코어 (userInteractive 스레드 8개) | 25초 |
| C2 | 식히기 | 15초 |
| D | GPU (Vision 이미지 분류) | 25초 |
| D2 | 식히기 | 15초 |
| E | ANE (Vision 이미지 분류). 시작할 때 ANE IORegistry 속성 저장 | 25초 |
| F | 식히기 | 20초 |

## 실행

터미널에서 실행합니다. 앞에 `sudo`를 붙이지 않습니다. 관리자 암호는 비교용 powermetrics에만 쓰여요. 5분쯤 걸리고, 측정 중에는 다른 무거운 작업을 피해 주세요.

```sh
bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/SensorProbe/measure.sh
```

## 결과 기록

- 검증 기기: MacBookPro18,1 (M1 Pro), macOS 27.0.1
- 결과: (측정 후 작성)
