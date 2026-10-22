# PowerProbe: CPU·GPU·ANE 전력과 ANE 사용률 진단

[설계 문서](../../docs/PROJECT_DESIGN.md) 7장 3·4번 항목을 확인합니다.

## 확인할 것

**1차: powermetrics 기본 출력**

1. powermetrics가 이 Mac(M1 Pro, macOS 27)에서 CPU·GPU·ANE 전력을 실제로 내보내는지, 단위는 무엇인지
2. ANE 활성 비율(residency)처럼 '사용률'로 쓸 수 있는 값이 나오는지
3. ANE에 일을 시켰을 때 그 값들이 반응하는지, GPU·CPU에만 일을 시켰을 때는 반응하지 않는지 (대조 실험)
4. E/P 클러스터별 활성 비율과 주파수가 어떻게 나오는지 (E/P 사용률을 정의할 재료)

**2차: 숨긴 정보와 관리자 권한 없는 읽기**

5. powermetrics의 숨긴 정보(`--unhide-info`, `--show-all`)에 ANE 활성 비율이 있는지
6. 관리자 권한 없이 IOReport로 읽은 CPU·GPU·ANE 에너지 카운터가 실제로 갱신되는지. macOS 27에서 이 카운터가 멈추고 powermetrics가 도는 동안에만 갱신된다는 보고가 여러 건 있어서([macmon #76](https://github.com/vladkens/macmon/issues/76), [macpow #20](https://github.com/k06a/macpow/issues/20)), powermetrics 없이 / 함께 / 끝난 뒤를 비교
7. IOReport에 ANE 관련 채널이 있는지, 그중 사용률로 쓸 만한 값이 있는지
8. E/P 사용률 후보 비교: powermetrics 클러스터 활성 비율, IOReport 코어·클러스터 활성 비율, OS CPU 시간(`host_processor_info`)
9. GPU 사용률 후보 비교: powermetrics GPU 활성 비율, IOReport GPU 활성 비율, IORegistry `Device Utilization %`

## 구성

- `ane_load.swift`: Vision 이미지 분류 요청을 지정한 장치(ANE·GPU·CPU)로 고정해서 반복 실행하는 부하 생성기. Core ML의 `MLComputeDevice`와 `VNRequest.setComputeDevice(_:for:)`로 장치를 지정하고, 실제로 그 장치가 쓰였는지는 powermetrics 수치로 확인
- `measure.sh`: 1차. 부하 생성기를 빌드한 뒤 가만히 있을 때 → ANE 부하 → GPU 부하 → CPU 부하 순서로 powermetrics를 10초씩 기록 (텍스트와 plist 형식)
- `ioreport_probe.swift`: 2차. 관리자 권한 없이 IOReport(비공개 라이브러리)와 OS 통계를 1초마다 읽어 기록하는 진단 도구. 앱에 넣을 코드가 아니라 확인용
- `measure2.sh`: 2차. 아래 순서로 기록
- `results/`: 1차 결과 원본
- `results-2/`: 2차 결과 원본

`measure2.sh`의 측정 순서:

| 단계 | 부하 | powermetrics | 확인 |
|---|---|---|---|
| A | 없음 | 안 돌림 | 권한 없이 읽은 카운터가 갱신되는지 |
| B | ANE | 안 돌림 | ANE 에너지와 ANE 관련 채널이 반응하는지 |
| C | ANE | 함께 돌림 | powermetrics가 돌 때만 갱신되는지 |
| D | CPU | 함께 돌림 | E/P 사용률 후보 3가지 비교 |
| E | GPU | 함께 돌림 | GPU 사용률 후보 3가지 비교 |
| H | 없음 → ANE | 숨긴 정보 옵션으로 실행 | ANE 활성 비율이 숨어 있는지 |
| F | 없음 | 끝난 뒤 | 카운터가 다시 멈추는지 |

## 실행

터미널에서 실행합니다. 관리자 암호를 한 번 물어봐요. 측정 중에는 다른 무거운 작업을 피해 주세요. 앞에 `sudo`를 붙이지 않습니다. 관리자 권한이 필요한 부분만 스크립트가 따로 `sudo`로 실행해요.

1차 (2분쯤):

```sh
bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/PowerProbe/measure.sh
```

2차 (5분쯤):

```sh
bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/PowerProbe/measure2.sh
```

## 결과 기록

- 검증 기기: MacBookPro18,1 (M1 Pro, E코어 2개 + P코어 8개), macOS 27.0.1 (26A434)

### 1차 (2026-10-22): powermetrics 기본 출력

`measure.sh`로 상태마다 1초 간격 10회를 기록했어요. 원본은 [`results/`](results)에 있어요. 부하 생성기는 세 장치 모두에서 지정한 대로 돌았고, Vision 이미지 분류를 초당 ANE 82.6회, GPU 56.0회, CPU 21.9회 처리했어요.

**전력** (10회 평균, 괄호는 최소~최대, 단위 mW)

| 상태 | CPU | GPU | ANE |
|---|---|---|---|
| 가만히 | 190 (31~496) | 3 (1~10) | 0 (0~0) |
| ANE 부하 | 822 (626~1,625) | 29 (27~31) | 367 (342~407) |
| GPU 부하 | 1,576 (905~3,661) | 6,846 (5,327~7,220) | 0 (0~0) |
| CPU 부하 | 6,701 (6,599~6,827) | 12 (12~13) | 0 (0~0) |

**HW 활성 비율** (10회 평균, 단위 %)

| 상태 | E 클러스터 | P0 클러스터 | P1 클러스터 | GPU |
|---|---|---|---|---|
| 가만히 | 47.2 | 6.5 | 0.3 | 2.6 |
| ANE 부하 | 38.9 | 43.2 | 0.6 | 21.8 |
| GPU 부하 | 35.6 | 35.6 | 2.4 | 97.1 |
| CPU 부하 | 26.5 | 86.3 | 28.4 | 7.5 |

확인한 것:

1. **CPU·GPU·ANE 전력이 나와요.** 단위는 mW이고, 관리자 권한(sudo)이 있어야 실행돼요. plist 형식에서는 `processor` 아래 `cpu_power`·`gpu_power`·`ane_power`(mW)와 `cpu_energy`·`gpu_energy`·`ane_energy`(mJ)예요.
2. **ANE 전력은 ANE 부하에만 반응해요.** 가만히·GPU 부하·CPU 부하에서는 10회 모두 정확히 0 mW였어요. ANE 부하가 CPU·GPU로 대신 실행되지 않고 실제로 ANE에서 돌았다는 뜻이에요.
3. **ANE 활성 비율과 주파수는 기본 출력에 없어요.** `ane_power` 샘플러 설명은 "dedicated rail ane power and frequency info"지만, 텍스트 출력에는 `ANE Power` 한 줄뿐이고 plist에도 전력·에너지 키만 있어요. 도움말에 숨긴 정보를 보이는 옵션(`--unhide-info`)과 모든 정보를 보이는 옵션(`--show-all`)이 있어서 2차에서 확인해요.
4. **E/P 구성:** E 클러스터는 CPU 0·1, P0 클러스터는 CPU 2~5, P1 클러스터는 CPU 6~9예요. 클러스터와 CPU마다 HW 활성 비율과 주파수가 나와요. plist에서는 `processor.clusters[]`의 `idle_ratio`·`freq_hz`와 그 안의 `cpus[]`예요.
5. **GPU:** 활성 비율이 GPU 부하에서 97%까지 올라가요. plist에서는 `gpu.idle_ratio`예요. `gpu.freq_hz`는 이름과 달리 MHz 단위 값이에요(389~1,222).
6. **함께 보인 것:** ANE 부하 중에도 GPU 활성 21.8%, P0 클러스터 43.2%가 나왔어요. Vision의 앞뒤 처리가 CPU·GPU에서 도는 것으로 보여요. 그래서 ANE 작업 중에는 CPU·GPU 수치도 함께 오를 수 있어요. 가만히 있을 때 CPU 전력은 31~496 mW로 크게 흔들려서, 순간값만 보여주면 숫자가 튀어 보일 수 있어요.

판정: 관리자 권한이 있으면 CPU·GPU·ANE 전력과 E/P·GPU 활성 비율을 얻을 수 있다. ANE 사용률은 기본 출력으로는 얻을 수 없다. 숨긴 정보 옵션과, 관리자 권한 없이 읽는 경로(IOReport)는 2차에서 확인한다.

### 2차: 숨긴 정보와 관리자 권한 없는 읽기

- 결과: (측정 후 작성)
