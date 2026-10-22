# PowerProbe: CPU·GPU·ANE 전력과 ANE 사용률 진단

[설계 문서](../../docs/PROJECT_DESIGN.md) 7장 3·4번 항목을 확인합니다.

## 확인할 것

1. powermetrics가 이 Mac(M1 Pro, macOS 27)에서 CPU·GPU·ANE 전력을 실제로 내보내는지, 단위는 무엇인지
2. ANE 활성 비율(residency)처럼 '사용률'로 쓸 수 있는 값이 나오는지
3. ANE에 일을 시켰을 때 그 값들이 반응하는지, GPU·CPU에만 일을 시켰을 때는 반응하지 않는지 (대조 실험)
4. E/P 클러스터별 활성 비율과 주파수가 어떻게 나오는지 (E/P 사용률을 정의할 재료)

## 구성

- `ane_load.swift`: Vision 이미지 분류 요청을 지정한 장치(ANE·GPU·CPU)로 고정해서 반복 실행하는 부하 생성기. Core ML의 `MLComputeDevice`와 `VNRequest.setComputeDevice(_:for:)`로 장치를 지정하고, 실제로 그 장치가 쓰였는지는 powermetrics 수치로 확인
- `measure.sh`: 부하 생성기를 빌드한 뒤 가만히 있을 때 → ANE 부하 → GPU 부하 → CPU 부하 순서로 powermetrics를 10초씩 기록 (텍스트와 plist 형식)
- `results/`: 측정 결과 원본

## 실행

터미널에서 아래 명령을 실행합니다. 관리자 암호를 한 번 물어보고, 2분쯤 걸립니다. 측정 중에는 다른 무거운 작업을 피해 주세요.

```sh
bash ~/Desktop/MonitorTool/MonitorTool/Diagnostics/PowerProbe/measure.sh
```

## 결과 기록

- 검증 기기: MacBookPro18,1 (M1 Pro), macOS 27.0.1
- 결과: (측정 후 작성)
