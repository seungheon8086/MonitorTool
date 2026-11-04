# DiskActiveProbe

디스크 **활성 시간**을 물리 디스크별로 재는 도구. 뜻은 Windows 작업 관리자의 '활성 시간'과 같다: 그 디스크에 요청이 하나라도 걸려 있던 시간의 비율. 커널 추적(kdebug)의 디스크 I/O 이벤트(시작·끝)를 root 권한으로 직접 읽어 센다.

앱에는 붙이지 않고 여기서 확인한 뒤, 중간 정리·최적화가 끝난 앱의 보조 프로그램(root)에 붙인다. 붙이는 설계는 결과를 보고 따로 정한다.

## 왜 이 방법인가

- IOBlockStorageDriver `Statistics`에는 쉰 시간이 없다(디스크마다 키 12개가 전부, DiskProbe). 걸린 시간 합 ÷ 구간은 평균 동시 요청이고, 활성 시간은 그보다 작거나 같다는 것만 안다(요청이 한 번에 하나일 때만 같음).
- Windows는 디스크가 비는 순간과 새 요청이 오는 순간을 커널이 찍어 쉰 시간을 세고, Linux도 같은 카운터(io_ticks)를 둔다. macOS에는 이 카운터가 없어서 이벤트로 직접 센다.
- 다른 길: SMART `controller_busy_minutes`는 이 SSD에서 늘 0, DTrace io는 SIP가 막음. IOReport 저장장치 채널(`ANS2 > Power > Duty cycle`, `ANS2 > Power State`, `NVMe > NVMe Power States`)은 권한 없이 읽히지만 전원 상태라 뜻이 다르다(2단계에서 같은 부하로 나란히 비교).

## 무엇을 세나

- 버퍼 I/O: 시작 = `spec_strategy`(인자 1 버퍼 주소를 섞은 값, 2 장치 번호, 3 블록, 4 바이트), 끝 = `buf_biodone`(인자 1 같은 버퍼 주소, 3 남은 바이트, 4 오류)
- 원시 장치(`/dev/rdiskN`) 읽기·쓰기: 시작·끝 모두 인자 1 = 스레드 ID
- 끝 이벤트에는 장치 번호가 없어서 인자 1로 시작과 짝을 짓는다(fs_usage와 같은 방식)
- 장치 번호 → IORegistry에서 위로 올라가 처음 만나는 IOBlockStorageDriver = 물리 디스크. 디스크 항목이 디스크를 구분하는 IORegistry ID와 같은 기준
- 디스크마다 걸린 요청 수가 0→1이면 바쁨 시작, 1→0이면 바쁨 끝. 바쁜 시간을 ns로 누적하고, 활성 % = 누적 차이 ÷ 구간
- 볼륨·파티션별로 세어 더하지 않는다. 같은 디스크의 볼륨들에 요청이 겹치면 두 번 세어져 100%를 넘을 수 있으므로, 이벤트를 먼저 물리 디스크로 모은다
- 디스크 이미지(`Virtual Interface`)는 뺀다. 그 아래 실제 파일 I/O가 disk0 이벤트로 따로 잡힌다

## 엔진 (나중에 보조 프로그램으로 옮길 부분)

| 파일 | 하는 일 |
|---|---|
| `Sources/Kdebug.swift` | 추적 켜기·형식 필터·읽기·해제, 이벤트 해석 |
| `Sources/DiskMap.swift` | 장치 번호 → 물리 디스크, IOBlockStorageDriver 통계 |
| `Sources/BusyMeter.swift` | 바쁜 시간 계산(순수 값 타입). 규칙은 `busy_meter_test.py`와 같고, python으로 경우별·무작위 검산 |

출력 모양(= 나중에 보조 프로그램이 앱에 줄 값): 물리 디스크별 누적 바쁜 시간(ns), 잃은 이벤트 수, 상태.
`Sources/Load.swift`(시험 부하)와 `Sources/main.swift`(명령)는 도구에만 쓴다.

## 안전장치

- 형식 필터는 디스크 I/O(`DBG_FSYSTEM / DBG_DKRW`)만 쓴다. 1단계는 관찰용으로 디스크 명령(`DBG_FSYSTEM / DBG_IOCTL`)과 드라이버 쪽 저장장치 종류(`DBG_IOKIT / DBG_IOSTORAGE`, `DBG_DRIVERS`의 저장장치·SD·NAND·SSD)도 받는다. 파일 경로·시스템 콜 이벤트는 받지 않는다
- 켤 때 남은 사용자 플래그(멈춤·연속 시각·특정 이벤트에서 멈춤)를 끈다. 시각은 mach_absolute_time 기준
- 공개 카운터와 대조: 작업 수·바이트·평균 동시 요청. 허용 범위는 1단계 결과로 정하고, 앱에서는 어긋나면 값 대신 '측정 불가'
- 끝날 때와 신호(Ctrl-C·종료)에 기록을 끄고 해제한다. 비정상 종료로 남은 추적은 `sudo ./run.sh reset`
- 다른 도구(fs_usage·Instruments)가 쓰는 중이면 기다리지 않고 '다른 도구가 사용 중'으로 끝낸다
- 이벤트 읽기 조각은 fs_usage 방식으로 갈아 끼울 수 있게 둔다(5단계 비교)

## 단계

1. **check** (지금): root 프로세스가 추적 자리를 얻는지, 이벤트 모양(짝 맞춤·장치 번호), 장치 → 물리 디스크 대응, 드라이버 통계와 작업 수·바이트 대조, 해제 뒤 tailspin이 돌아오는지, powermetrics와 함께 도는지, 디스크 명령(캐시 비우기·TRIM)이 이벤트로 나오는지, 드라이버 단계 이벤트(명령마다 찍히는 것)가 있는지. 부하: 쉼 5초 → 쓰기 512 MiB → 순차 읽기 1 GiB → 무작위 4 KiB 동시 1 · 3초 → 동시 8 · 2초 → 쉼 3초
   - 바이트가 드라이버보다 적으면 커널 추적에 안 보이는 I/O가 있다는 뜻(APFS가 IOKit으로 바로 보내는 I/O 등). 그만큼 활성 시간이 낮게 나올 수 있다
2. **live · record**: 실시간 보기(1초마다 디스크별 활성 %·평균 동시 요청), DiskProbe와 같은 부하 단계, 짧게 몰리는 부하, 실사용 기록, IOReport 저장장치 채널과 나란히 비교
3. 공존·정리: powermetrics·Instruments·fs_usage와 함께, 강제 종료 뒤 reset, tailspin 상태
4. 비용·오래 켜 두기: 가만히·무거운 부하의 CPU와 깨어남(버퍼 기준치 대기 `KERN_KDBUFWAIT`), 커널 버퍼 메모리, 잠자기
5. fs_usage 방식과 비교: 같은 부하로 비용·값 차이

결과를 모아 붙일지, 어떻게 붙일지 정한다.

## 실행

- `sudo ./run.sh check` — 약 30초. 결과: `results/<시각>/`
  - `check.txt`(화면과 같은 요약), `phases.tsv`(단계 × 디스크), `devices.tsv`(장치 → 물리 디스크), `events.tsv`(원본 이벤트), `tailspin-before.txt`·`tailspin-after.txt`, `ktrace-log.txt`(커널의 소유권 변화 기록)
- `sudo ./run.sh status` — 지금 커널 추적을 누가 쓰는지(읽기만)
- `sudo ./run.sh reset` — 비정상 종료로 남은 추적 정리(살아 있는 소유자가 있으면 손대지 않음)
- `python3 -I analyze_ssd.py results/<시각>/events.tsv` — SSD 드라이버 이벤트·디스크 명령 분석(1단계 관찰)
- 빌드는 스크립트가 sudo를 부른 사용자 권한으로 한다(`build/diskactiveprobe`, 소스가 바뀌었을 때만)

## 주의

- 최적화 쪽 측정(ResourceProbe)과 동시에 돌리지 않는다. 추적이 켜져 있으면 시스템 상태가 달라진다
- 돌리는 동안 fs_usage·Instruments는 쓸 수 없고 tailspin 기록이 멈춘다(해제하면 돌아옴)
- 측정 전에 게임·LM Studio·다른 모니터 앱을 닫는다
- 원본 `.tsv`는 커밋하지 않는다(`.gitignore`), 필요하면 `.tsv.gz`만

## 근거 (XNU xnu-12377.1.9, system_cmds-1042.100.6)

- 명령 번호(`sys/sysctl.h`): KERN_KDEBUG 24 > KDDFLAGS 2 · KDENABLE 3 · KDSETBUF 4 · KDGETBUF 5 · KDSETUP 6 · KDREMOVE 7 · KDREADTR 10 · KDSET_TYPEFILTER 22 · KDBUFWAIT 23
- 시각: 기본은 mach_absolute_time, `KDBG_CONTINUOUS_TIME`이면 mach_continuous_time(`kern/kdebug_common.c`). 배경 도구에서 가져올 때의 초기화(`kdbg_clear`)가 이 플래그를 끈다
- `kd_buf` 64바이트(시각 · 인자 1~4 · 스레드 ID · debugid · cpuid · 빈칸), `kbufinfo_t.bufid` = 소유 프로세스 pid(`sys/kdebug_private.h`)
- KDREADTR는 넣을 때 바이트, 나올 때 이벤트 수. 형식 필터는 8 KiB 비트맵이고 커널이 `DBG_TRACE`를 늘 허용한다. 버퍼가 넘치면 `TRACE_LOST_EVENTS`가 끼어든다(`kern/kdebug.c`)
- 소유권: root면 가져올 수 있고, 배경 도구(tailspind)에서 가져오면 그 설정이 초기화된다. 소유 프로세스가 끝나도 기록은 계속되고, 해제하면 배경 도구에 알린다(`kern/kern_ktrace.c`)
- 버퍼: 저장 단위 하나에 2,048개, CPU마다 최소 4단위 → 최소 (CPU·보조 프로세서 수 + 16) × 8,192개 × 64바이트. 대기 기준치 = 단위 수의 절반(`kern/kdebug.c`)
- 이벤트 인자: `miscfs/specfs/spec_vnops.c`(시작, 원시 장치, 디스크 명령), `vfs/vfs_bio.c`(끝). 짝 맞춤은 `fs_usage.c`의 diskio_start·diskio_complete와 같음

## 결과

### 1단계 check (2026-11-04 15:13, MacBookPro18,1, macOS 27.2, `results/20261104-151340`)

- 조건: MonitorTool 앱 켜 둠(보조 프로그램의 powermetrics 실행 중). MapleStory Worlds가 켜져 있었음(쉼 단계의 배경 I/O 181 MB)
- 빌드 통과. root 프로세스가 추적 자리를 얻음
  - 시작 전 소유자: tailspind(배경, 버퍼 0개·기록 꺼짐). 이 Mac은 tailspin이 꺼져 있음(기본값)이라 지워질 tailspin 기록이 없었음
  - 커널 기록: 배경(2) → 전경(1) 'owned by diskactiveprobe'. 해제 뒤 'promoting background tool', 2 ms 안에 tailspind가 다시 배경 소유
- powermetrics: 같은 pid로 끝까지 실행. 커널 추적 자리를 쓰지 않아 함께 돈다
- 커널 버퍼: 26만 개를 요청했지만 커널이 최솟값 36.9만 개(22.5 MiB)로 올림 = (CPU·보조 프로세서 29 + 여유 16) × 4단위 × 2,048개. 고정(wired) 커널 메모리라 켜 둔 동안 늘 묶인다. 플래그로는 줄일 수 없음
- 이벤트: 시작 221,583 = 끝 221,583(짝 100%), 잃음 0, 시각 거꾸로 0
- 드라이버 통계와 대조: 모든 단계에서 작업 수·바이트가 같음(합계 2,686.3 MB = 2,686.3 MB). 이 부하에서 커널 추적에 안 보이는 디스크 I/O는 없음
- 장치 → 물리 디스크: disk3s1(Data) 220,721 · disk3(APFS 컨테이너) 750 · disk3s4 58 · disk3s3s1 44 → 모두 disk0
  - 못 찾은 장치 (3,2) = /dev/null. mm 장치(/dev/mem·kmem·null·zero)가 cdevsw에서 `D_DISK`로 표시돼 있어 쓸 때마다 디스크 I/O 이벤트가 나옴(`dev/arm64/conf.c`). IOMedia가 없으니 그대로 뺀다

| 단계 (disk0) | 길이 | 활성 | 평균 동시 요청 | 응답 ms (추적 중앙 · 드라이버 평균) |
|---|---|---|---|---|
| 쉼 | 5.04초 | 7.6% | 0.10 | 0.17 · 0.16 |
| 쓰기 1 MiB | 0.27초 | 85.3% | 0.85 | 0.17 · 0.35 |
| 순차 읽기 1 MiB | 0.36초 | 96.3% | 0.96 | 0.34 · 0.34 |
| 무작위 4 KiB 동시 1 | 3.00초 | 91.7% | 0.91 | 0.08 · 0.08 |
| 무작위 4 KiB 동시 8 | 2.00초 | 100.0% | 7.08 | 0.08 · 0.08 |

- 요청이 한 번에 하나면 활성 ≈ 평균 동시 요청(차이 1% 안, 추적이 드라이버보다 조금 위에서 재서 활성이 조금 큼). 동시 8에서는 활성이 100%에서 멈추고 평균 동시 요청은 7.08 → 둘은 다른 것을 보여 준다
- 디스크 명령(`DBG_IOCTL`): 동기화 요청(DKIOCSYNCHRONIZE) 24개(옵션 2 = 장벽 21개, 옵션 0 = 전체 3개)와 TRIM 범위 10개(1.09 MB). 시작·끝 없이 한 번 찍히는 이벤트라 걸린 시간이 없음(check의 명령별 표가 빈 까닭)
- SSD 드라이버 이벤트(`DBG_DRIVERS / DBG_SSD` 0x0615, 관찰만, `analyze_ssd.py`)
  - NVMe 명령마다 제출(0x0615002c)·완료(0x06150028)가 태그(1~252)로 짝지어 나옴. 221,598개 짝 100%, 명령 시간 중앙 0.072 ms · 90% 0.084 ms
  - 캐시 비우기(0x06154009·0x0615400a) 19번, 합 18.5 ms, 가장 긴 것 13.2 ms(512 MiB 쓰기 뒤의 F_FULLFSYNC로 보임). TRIM(0x0615400d·0x0615400e) 5번, 합 1.0 ms
  - 14초 동안 바쁜 시간: 디스크 I/O 기준 5,714 ms · NVMe 명령 기준 5,464 ms · 합집합 5,729 ms. 디스크 I/O 이벤트에 안 잡히는 몫(거의 캐시 비우기)은 0.3%
  - 쓰지 않음: 뜻을 Apple 비공개 드라이버에서 추측해야 하고, 디스크 I/O 이벤트가 드라이버 통계와 100% 맞는다. 다만 캐시 비우기 시간은 디스크 I/O 이벤트로는 못 잰다(알려진 틈, fsync가 잦은 부하에서 얼마나 큰지 2단계에서 본다)
- 비용(무거운 부하 14초): 0.1초마다 읽기 141번, 한 번에 최대 52,735개, 읽기 CPU 144 ms(이벤트 110만 개, 개당 약 0.13 µs). SSD 이벤트를 빼면 44만 개
- 2단계에서 고칠 것: 디스크 명령은 한 번 찍히는 이벤트로 세기, 디스크가 아닌 장치는 이름으로 표시, `phases.tsv`에 단계 시작 시각, 형식 필터에서 SSD 이벤트 빼기, 읽기 버퍼(16 MiB) 줄이기
- 원본 `events.tsv`(70 MB)는 커밋하지 않음
