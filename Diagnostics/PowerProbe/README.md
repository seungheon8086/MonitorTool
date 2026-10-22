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

**3차: ANE 부분 부하와 남은 확인**

10. ANE에 일을 띄엄띄엄 줄 때(초당 요청 수 제한) ANE 전원 상태 ACT 비율이 일한 양(ANE 메모리 트래픽)에 비례하는지
11. CPU 번호와 E/P 묶음의 대응을 IODeviceTree(`cluster-type`)에서 읽을 수 있는지
12. powermetrics `--show-extra-power-info`에 ANE 활성 비율이 있는지

## 구성

- `ane_load.swift`: Vision 이미지 분류 요청을 지정한 장치(ANE·GPU·CPU)로 고정해서 반복 실행하는 부하 생성기. Core ML의 `MLComputeDevice`와 `VNRequest.setComputeDevice(_:for:)`로 장치를 지정하고, 실제로 그 장치가 쓰였는지는 powermetrics 수치로 확인. 세 번째 인자로 초당 요청 수를 제한할 수 있음(3차)
- `measure.sh`: 1차. 부하 생성기를 빌드한 뒤 가만히 있을 때 → ANE 부하 → GPU 부하 → CPU 부하 순서로 powermetrics를 10초씩 기록 (텍스트와 plist 형식)
- `ioreport_probe.swift`: 2차. 관리자 권한 없이 IOReport(비공개 라이브러리)와 OS 통계를 1초마다 읽어 기록하는 진단 도구. 앱에 넣을 코드가 아니라 확인용
- `measure2.sh`: 2차. 아래 순서로 기록
- `measure3.sh`: 3차. CPU 묶음 대응 출력 → 가만히 → ANE 부하를 초당 최대·48·24·12·4회로 바꿔 가며 IOReport 기록 → ANE 부하 중 `--show-extra-power-info`
- `results/`: 1차 결과 원본
- `results-2/`, `results-3/`: 2차·3차 결과 원본

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

3차 (3분쯤):

```sh
bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/PowerProbe/measure3.sh
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

### 2차 (2026-10-22): 숨긴 정보와 관리자 권한 없는 읽기

`measure2.sh`로 기록했어요. 단계별 요약은 `results-2/ioreport-*.txt`와 `pm-*.txt`에 있어요. 표본별 원본은 압축 파일(`*.tsv.gz`)로 저장했어요. IOReport는 모두 일반 사용자(uid 501)로 읽었고, 관리자 권한 없이 조회되는 채널은 9,359개였어요(`channels.tsv.gz`).

**1) 관리자 권한 없이 읽은 에너지 카운터** (Energy Model 162개 채널, 칸의 숫자는 값이 바뀐 표본 수 / 전체 표본 수)

| 단계 | powermetrics | 값이 바뀐 채널 | CPU Energy | ANE0 | GPU Energy |
|---|---|---|---|---|---|
| A 가만히 | 안 돌림 | 1/162 | 0/20 | 0/20 | 20/20 |
| B ANE 부하 | 안 돌림 | 1/162 | 0/30 | 0/30 | 30/30 |
| C ANE 부하 | 함께 돌림 | 152/162 | 20/20 | 20/20 | 20/20 |
| D CPU 부하 | 함께 돌림 | 97/162 | 20/20 | 1/20 | 20/20 |
| E GPU 부하 | 함께 돌림 | 133/162 | 20/20 | 0/20 | 20/20 |
| F 가만히, 끝난 뒤 | 안 돌림 | 1/162 | 0/20 | 0/20 | 20/20 |

- 이 Mac(macOS 27.0.1)에서도 보고와 같았어요. **CPU·ANE·DRAM 에너지 카운터는 관리자 권한 샘플러(powermetrics)가 도는 동안에만 갱신**되고, 끝나면 바로 다시 멈춰요. 멈춘 동안 쌓인 에너지는 다음 갱신 때 한꺼번에 들어와요. C의 첫 표본에서는 CPU 에너지가 1초 만에 360 J 늘어서 계산상 358 W가 나왔어요.
- 갱신되는 동안의 값은 powermetrics와 맞아요. 첫 두 표본을 뺀 평균은 C의 CPU 2.05 W(powermetrics 2.25 W)·ANE 0.98 W(1.02 W), D의 CPU 7.65 W(7.74 W)였어요.
- **GPU Energy(nJ) 채널만 관리자 권한 없이 계속 갱신**돼요. E의 GPU 7.73 W는 powermetrics의 7.58 W와 맞아요.

**2) ANE 관련 채널** (관리자 권한 없이)

| 단계 | ANE0 전원 상태 ACT 비율 | ANE0 메모리 읽기 | ANE0 메모리 쓰기 |
|---|---|---|---|
| A 가만히 | 0% | 0 | 0 |
| B ANE 부하 | 100% | 7.2 GB/s | 3.4 GB/s |
| C ANE 부하 + powermetrics | 100% | 7.4 GB/s | 3.4 GB/s |
| D CPU 부하 | 0% | 0 | 0 |
| E GPU 부하 | 0% | 0 | 0 |
| F 가만히, 끝난 뒤 | 0.13% | 1회만 0이 아님 | 1회만 0이 아님 |

- `SoC Stats / Cluster Power States / ANE0`는 상태가 `INACT`·`ACT` 두 개인 채널이에요. ACT 시간 비율이 ANE 부하에서만 100%가 되고 CPU·GPU 부하에서는 0%예요. **powermetrics 없이도 갱신돼요.** 지금까지 찾은 값 중 ANE의 '활성 시간 비율'에 가장 가까워요.
- `AMC Stats / Perf Counters / ANE0 RD·WR`(바이트)는 ANE의 메모리 트래픽이에요. 이것도 ANE 부하에만 반응해요.
- 다만 이번 부하는 ANE를 쉬지 않고 돌렸어요. ACT 비율이 실제로 일한 시간에 비례하는지, 잠깐만 일해도 켜진 채로 머무는지는 아직 몰라요. 부하를 띄엄띄엄 주는 부분 부하 실험이 필요해요.

**3) E/P 사용률 후보** (D 단계 CPU 부하 동안 동시에 기록, 단위 %)

| 구분 | powermetrics 클러스터 활성 | IOReport 클러스터 활성 | IOReport 코어 활성 평균 | OS CPU 시간 평균 |
|---|---|---|---|---|
| E (CPU 0·1) | 54.3 | 50.1 | 38.0 | 35.4 |
| P0 (CPU 2~5) | 80.0 | 79.7 | 27.6 | 26.1 |
| P1 (CPU 6~9) | 49.7 | 48.7 | 14.8 | 13.8 |

- IOReport의 클러스터 활성 비율(`CPU Complex Performance States`)은 powermetrics의 클러스터 HW 활성 비율과 같은 값이고, 관리자 권한 없이 읽혀요.
- 클러스터 활성 비율은 '코어가 하나라도 일한 시간'이라서 코어 평균보다 훨씬 높게 나와요(P0: 80% 대 26~28%).
- 코어별 활성 비율(IOReport `CPU Core Performance States`)과 OS가 집계한 CPU 시간(`host_processor_info`)은 코어마다 차이가 4%p 이내로 비슷해요. IOReport 쪽이 조금 높아요. IOReport 코어 채널 이름(`ECPU000`, `PCPU000`…)의 순서는 CPU 번호 순서와 맞았어요.

**4) GPU 사용률 후보** (단위 %)

| 단계 | powermetrics GPU HW 활성 | IOReport GPUPH 활성 | IORegistry Device Utilization |
|---|---|---|---|
| A 가만히 | (안 돌림) | 24.2 | 15.0 |
| C ANE 부하 | 40.0 | 39.9 | 4.5 |
| D CPU 부하 | 28.5 | 28.6 | 8.3 |
| E GPU 부하 | 98.5 | 98.5 | 69.6 |

- IOReport의 GPU 활성 비율은 powermetrics와 같은 값이고, 관리자 권한 없이 읽혀요. GPU가 조금씩만 일해도 깨어 있는 시간이 길면 올라가요.
- IORegistry `Device Utilization %`는 다른 지표예요. GPU 부하에서 70%, ANE 부하처럼 GPU가 잠깐씩만 쓰이는 상황에서는 5% 안팎이에요.

**5) powermetrics 숨긴 정보**

- `--unhide-info`는 샘플러 이름을 받지 않았어요(`unrecognized unhide option: cpu_power`). 받는 값은 찾지 못했어요.
- `--show-all`에서도 ANE는 `ANE Power` 줄뿐이었어요.
- 도움말의 `--show-extra-power-info`("unsupported power info")는 이번에 시험하지 않았어요.

판정:

- 관리자 권한 없이 읽을 수 있는 것: GPU 전력, E/P 클러스터·코어 활성 비율, OS CPU 시간, GPU 활성 비율과 Device Utilization, ANE 전원 상태(ACT) 비율, ANE 메모리 트래픽.
- CPU·ANE 전력은 이 Mac의 macOS 27.0.1에서 관리자 권한 샘플러가 돌 때만 갱신된다. 실시간으로 보여주려면 관리자 권한이 필요하다.
- ANE 사용률의 후보는 IOReport ANE0 전원 상태의 ACT 비율이다. 부분 부하에서 일한 시간에 비례하는지 3차에서 확인한다.

### 3차 (2026-10-23): ANE 부분 부하와 남은 확인

`measure3.sh`로 기록했어요. 원본은 `results-3/`에 있어요.

**1) ANE 부분 부하** (관리자 권한 없이, 단계마다 12초)

| 초당 ANE 요청 | ANE0 전원 상태 ACT 비율 | ANE0 메모리 읽기 | 요청 1회당 읽기 |
|---|---|---|---|
| 0 (가만히) | 0% | 0 | - |
| 4 | 100% | 242 MB/s | 61 MB |
| 12 | 100% | 704 MB/s | 59 MB |
| 24 | 100% | 1,369 MB/s | 57 MB |
| 48 목표 (실제 약 32) | 100% | 1,924 MB/s | 60 MB |
| 제한 없음 (실제 약 31) | 100% | 1,863 MB/s | 60 MB |

(메모리 읽기는 두 번째 표본부터의 중앙값. 첫 표본은 1초보다 조금 긴 구간을 담고 있어서 뺐어요.)

- **ACT 비율은 일한 양에 비례하지 않아요.** 초당 4회만 요청해도 모든 표본에서 100%였어요. ANE가 한 번 켜지면 요청 사이(약 0.25초)에도 꺼지지 않아서, 이 값은 'ANE 전원이 켜져 있던 시간'이지 '일한 시간'이 아니에요. 쓰는 중인지 아닌지만 구분할 수 있어요.
- **ANE 메모리 트래픽은 일한 양에 비례해요.** 요청 1회당 약 57~61 MB로 거의 일정했어요.
- 측정하는 동안 다른 프로그램이 GPU를 계속 쓰고 있었어요. 가만히 단계에서도 GPU 활성 95%, Device Utilization 68%였어요. Vision 요청의 앞뒤 처리가 GPU를 쓰기 때문에, 48회와 제한 없음 단계는 초당 약 32회에 그쳤어요. 가만히 단계의 ANE 값은 모두 0이어서 다른 프로그램이 ANE를 쓰지는 않았어요.

**2) CPU 번호와 E/P 묶음** (`IODeviceTree:/cpus`, 관리자 권한 없이)

| CPU 번호 | cluster-type | cluster-id |
|---|---|---|
| 0, 1 | E | 0 |
| 2~5 | P | 1 |
| 6~9 | P | 2 |

`logical-cpu-id`는 CPU 번호와 같았고, 1차의 powermetrics 클러스터 구성과도 맞아요. 앱은 코어 순서를 가정하지 않고 이 값으로 E/P를 나눌 수 있어요.

**3) powermetrics `--show-extra-power-info`**

ANE는 `ANE Power` 줄뿐이었어요. 기본 출력, `--show-all`, `--show-extra-power-info` 어디에도 ANE 활성 비율은 없었어요.

판정:

- 이 Mac에서 ANE가 '일한 시간 비율'을 직접 재는 값은 찾지 못했다. powermetrics에는 없고, IOReport의 ACT 비율은 전원 상태라 사용률로 쓸 수 없다.
- 실제로 잴 수 있는 ANE 지표는 전력(관리자 권한), 사용 중인지 여부(ACT, 권한 불필요), 메모리 트래픽(권한 불필요, 일한 양에 비례)이다.
- CPU 번호와 E/P 묶음의 대응은 IODeviceTree의 `cluster-type`으로 읽는다.
