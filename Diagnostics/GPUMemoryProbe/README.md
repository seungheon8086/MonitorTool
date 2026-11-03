# GPUMemoryProbe: GPU 메모리 사용량 진단

GPU 칸에 Windows 작업 관리자처럼 GPU 메모리 사용량을 넣을 수 있는지 확인해요. (2026-11-03, M1 Pro, macOS 27.2 26B123)

## 확인할 것

1. 관리자 권한 없이 GPU 메모리 값을 읽을 수 있는지. 후보는 GPU 사용률을 읽는 IORegistry `IOAccelerator`의 `PerformanceStatistics`
2. 그 값이 GPU 사용에 따라 움직이는지 (가만히 → GPU 부하 → 끝난 뒤)
3. 그 값이 Windows의 GPU 메모리처럼 '앱들이 할당한 양'인지, 미리 잡아 둔 예약량인지 (정해진 크기 할당 시험)
4. 가만히 있을 때 값이 큰 이유 (켜 둔 앱 때문인지)

## 구성

- `measure.sh`: 1차. `PerformanceStatistics` 전체 키를 기록하고, 가만히 10초 → GPU 부하 15초(PowerProbe `ane_load` gpu) → 끝난 뒤 10초를 1초마다 기록
- `gpu_alloc.swift`: Metal로 공유 버퍼 1 GiB → GPU 전용 버퍼 1 GiB를 할당하고(실제로 써서 메모리를 차지하게 함) 하나씩 놓으면서 IORegistry 값을 읽는 시험 프로그램. GPU 권장 최대치(`recommendedMaxWorkingSetSize`)도 기록
- `measure-alloc.sh`: 2차. `gpu_alloc` 실행 → (선택) 쓰지 않는 앱을 닫기 전후의 가만히 값
- `results/`, `results-2/`: 1차·2차 결과 원본 (`samples.tsv`는 압축본만)

## 결과

**1차: 읽을 수 있는 키** — `PerformanceStatistics`에 `Alloc system memory`, `In use system memory`, `In use system memory (driver)`(늘 0), `Allocated PB Size`, `Device·Renderer·Tiler Utilization %` 등이 있어요. GPU는 `AGXAcceleratorG13X` 하나예요.

| 구간 | GPU 사용률 | `Alloc system memory` | `In use system memory` |
|---|---|---|---|
| 가만히 | 0~46% | 4.21~4.39 GB | 0.23~1.00 GB |
| GPU 부하 | 68~70% | 4.63 → 5.06 GB | 0.41~0.62 GB |
| 끝난 뒤 | 0% | 4.12 GB | 0.19~0.32 GB |

**2차: 할당 시험** (1 GiB = 1.074 GB)

| 단계 | 할당한 양 | Alloc 증가 | 시험 프로그램 `currentAllocatedSize` | In use |
|---|---|---|---|---|
| 공유 1 GiB | 1.074 GB | +1.056 GB | 1.074 GB | 0.196 GB |
| + GPU 전용 1 GiB | 2.147 GB | +2.119 GB | 2.148 GB | 0.014 GB |
| GPU 전용 놓음 | 1.074 GB | +1.051 GB | 1.074 GB | 0.204 GB |
| 모두 놓음 | 0 | +1.051 GB | 1.074 GB | 0.266 GB |

마지막 단계는 시험 프로그램이 공유 버퍼를 아직 놓지 않은 상태였어요(자기 할당량도 1.074 GB로 보고, Swift 자동 해제 시점 때문). Alloc은 모든 단계에서 그 프로그램의 실제 할당량을 98~99% 따라갔어요.

**가만히 있을 때**: Chrome·Discord·Telegram·Safari·Xcode 등을 닫은 뒤 2.67~2.77 GB(닫기 전 4.2~4.4 GB). GPU에 연결된 프로세스는 닫기 전 약 45종, 닫은 뒤 33종. 남은 값은 WindowServer(창마다 보관하는 그림, Retina 해상도)·배경화면·위젯 등 macOS 쪽 몫이 대부분으로 보여요. 프로세스별 값은 IORegistry에 없어서 더 나누지 못했어요.

**GPU 권장 최대치**: 11.84 GiB(12.7 GB, 16 GiB의 약 74%).

## 판정

- `Alloc system memory` = 앱들이 GPU용으로 할당한 메모리 합계. Windows 작업 관리자의 GPU 메모리(내장 그래픽의 '공유 GPU 메모리')와 같은 계열이에요. 관리자 권한 없이 GPU 사용률과 같은 사전에서 읽어요.
- `In use system memory`는 할당과 상관없이 0.01~1 GB를 오가서 쓰지 않아요.
- 통합 메모리라 이 값은 메모리 칸의 '사용량'에 이미 들어 있어요.
- GPU 칸에 '메모리 N GB'(막대 없음)와 상세 그래프 계열 하나로 넣어요. (2026-11-03 사용자 결정, B안)
