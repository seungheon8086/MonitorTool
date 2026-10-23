# HelperProbe: 관리자 권한 보조 프로그램 진단

[설계 문서](../../docs/PROJECT_DESIGN.md)에서 정한 대로, CPU·ANE 전력은 관리자 권한으로 도는 작은 보조 프로그램이 읽어서 앱에 전달해요. 이 진단 앱은 그 구조가 이 Mac에서 개인 팀 서명으로 동작하는지 확인해요.

## 확인할 것

1. 앱이 `SMAppService.daemon(plistName:)`으로 보조 프로그램(LaunchDaemon)을 등록할 수 있는지, 개인 팀 서명으로도 되는지
2. 사용자가 시스템 설정에서 허용하면 보조 프로그램이 관리자 권한(root, uid 0)으로 실행되는지
3. 앱과 보조 프로그램이 XPC로 값을 주고받는지. 양쪽이 서로의 코드 서명(같은 팀)을 확인한 뒤에만 연결되는지
4. 보조 프로그램이 정해진 인자로 powermetrics를 실행해서 CPU·GPU·ANE 전력을 앱에 돌려줄 수 있는지
5. Xcode 디버거를 붙여 실행한 앱도 보조 프로그램이 받아 주는지. 디버거가 중단점을 넣으려고 앱 코드를 고치면 커널이 그 프로세스의 서명 유효 표시(`CS_VALID`)를 지워요([xnu `cs_invalid_page`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_cs.c)). 연결할 때 서명이 유효하지 않으면 서명 확인에서 거절된다는 [Apple DTS 설명](https://developer.apple.com/forums/thread/797913)도 있어요. MonitorTool을 Xcode에서 어떻게 실행하며 개발할지 정하는 데 필요해요
6. 등록 해제가 되는지

## 구성

- `HelperProbe/`: 진단 앱(SwiftUI). 등록·해제, 상태 표시, XPC 호출 버튼과 기록. 앱 자신의 코드 서명 상태(커널의 CS 플래그)도 보여 줘요. 기록은 앱을 다시 실행해도 이어지고, **기록 지우기**로 비워요
- `HelperProbeDaemon/`: 보조 프로그램(명령줄 도구). `NSXPCListener`로 같은 팀이 서명한 HelperProbe 앱의 연결만 받고, 권한 확인과 powermetrics 1회 실행만 해요. 다른 명령은 받지 않아요
- `Shared/HelperProtocol.swift`: 앱과 보조 프로그램이 함께 쓰는 XPC 약속, 이름, 서명 요구사항
- `LaunchDaemons/com.seungheon.HelperProbe.daemon.plist`: launchd 설정(`Label`, `BundleProgram`, `MachServices`, `AssociatedBundleIdentifiers`). 빌드할 때 앱 안의 `Contents/Library/LaunchDaemons/`로 복사되고, 보조 프로그램 실행 파일은 `Contents/MacOS/`로 복사돼요(복사할 때 다시 서명)
- 스킴 두 개: **HelperProbe**는 디버거 없이 실행하고(확인 1–4, 6), **HelperProbe-Debugger**는 LLDB를 붙여 실행해요(확인 5)
- 두 타깃 모두 개인 팀(`47C8XKJT3X`)으로 자동 서명해요. 앱은 App Sandbox를 쓰지 않아요
- 참고: [Apple 개발자 포럼의 SMAppService 예제 설명](https://developer.apple.com/forums/thread/802443)

## 실행 순서

1. Finder에서 `HelperProbe.xcodeproj`를 열어요. 상단 스킴이 **HelperProbe**인지 확인하고 ⌘R로 실행해요. 이 스킴은 디버거 없이 실행해서, Xcode 아래쪽 디버그 영역이 조용해도 정상이에요.
2. 앱 창에서 **1. 등록**을 눌러요. '백그라운드 항목 추가됨' 알림이 뜨고, 상태가 '허용 필요'가 될 수 있어요.
3. **시스템 설정 열기**를 눌러요. 열린 로그인 항목 화면의 백그라운드 허용 목록에서 HelperProbe를 켜요. 관리자 암호나 Touch ID를 물어볼 수 있어요.
4. 앱으로 돌아오면 상태가 '사용 중 (허용됨)'으로 바뀌어요.
5. **2. 누구 권한으로 도는지 묻기**를 눌러요. 응답에 `uid 0`이 보이면 관리자 권한으로 도는 거예요.
6. **3. 전력 한 번 재기**를 눌러요. 1초쯤 뒤 CPU·GPU·ANE 전력이 나오면 성공이에요.
7. 디버거 비교: Xcode에서 ■ 버튼(⌘.)으로 앱을 멈추고, 스킴을 **HelperProbe-Debugger**로 바꿔 ⌘R로 다시 실행해요. **2**를 눌러요. 오류가 나도 괜찮아요. 그걸 확인하는 단계예요.
8. **4. 등록 해제**를 눌러 보조 프로그램을 지워요.
9. **기록 복사**를 눌러 Claude에게 붙여 넣어 주세요. 앞 실행의 기록까지 함께 복사돼요.
10. 스킴을 **HelperProbe**로 되돌려 놓아요.

막히면 기록에 나온 오류 코드와 함께, 터미널에서 보조 프로그램 로그를 볼 수 있어요.

```sh
log show --last 10m --predicate 'process == "HelperProbeDaemon"'
```

## 결과 기록 (2026-10-23)

- 검증 기기: MacBookPro18,1 (M1 Pro), macOS 27.0.1, Xcode 27.1, 개인 팀 서명
- 원본 기록: [results/2026-10-23-log.txt](results/2026-10-23-log.txt)

| 확인 | 결과 |
|---|---|
| 1. 개인 팀 서명으로 등록 | **됨.** 첫 `register()`는 `Operation not permitted`(`SMAppServiceErrorDomain` 1)를 던지지만, 항목은 추가되고 상태가 '허용 필요'가 돼요. 실패가 아니라 사용자 허용을 기다린다는 신호예요 |
| 2. 허용 뒤 관리자 권한 실행 | **됨.** 시스템 설정에서 허용하자 보조 프로그램이 `uid 0, euid 0`으로 응답했어요 |
| 3. XPC 통신과 서명 확인 | **됨.** 앱은 같은 팀이 서명한 보조 프로그램만, 보조 프로그램은 같은 팀이 서명한 `com.seungheon.HelperProbe`만 받도록 요구사항을 건 상태에서 주고받았어요. 맞지 않는 프로그램이 거절되는지는 시험하지 않았어요 |
| 4. powermetrics 대리 실행 | **됨.** CPU 924 mW, GPU 26 mW, ANE 0 mW, 합계 950 mW. 요청부터 응답까지 1.8초(표본 1초 + 실행 준비 약 0.8초) |
| 5. 디버거를 붙인 앱 | **연결됨.** 디버거 흔적(`CS_DEBUGGED`)은 켜졌지만 서명 유효 표시(`CS_VALID`)가 그대로라 거절되지 않았어요. 앱 시작 때와 3초 뒤 요청 때 모두 유효했어요. 중단점에 멈췄다가 다시 간 뒤는 시험하지 않았어요 |
| 6. 등록 해제 | **됨.** 상태가 '등록 안 됨'으로 바뀌었고, 한 번 더 눌러도 성공으로 끝났어요 |

### 앱 서명 상태(커널 CS 플래그)

| 실행 | 값 | 켜진 플래그 |
|---|---|---|
| 디버거 없이 | `0x62000205` | `VALID`, `GET_TASK_ALLOW`, `KILL`, `NO_UNTRUSTED_HELPERS`, `SIGNED`, `DEV_CODE` |
| 디버거 연결 | `0x72000025` | `VALID`, `GET_TASK_ALLOW`, `INVALID_ALLOWED`, `NO_UNTRUSTED_HELPERS`, `DEBUGGED`, `SIGNED`, `DEV_CODE` |

디버거가 붙으면 커널은 `KILL`을 끄고 `INVALID_ALLOWED`·`DEBUGGED`를 켜요. 고쳐진 코드 페이지가 실행돼도 앱을 죽이지 않겠다는 뜻이에요. 그래도 고쳐진 페이지가 실제로 실행되기 전까지는 `VALID`가 남아 있고, 이번 실행에서는 끝까지 남아 있었어요. 플래그 이름과 값은 [xnu `cs_blobs.h`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h)를 따랐어요.

### MonitorTool에 반영할 것

- 보조 프로그램 구조는 개인 팀 서명으로 그대로 쓸 수 있어요.
- 첫 등록 때의 오류 1은 실패로 보여주지 않아요. '시스템 설정에서 허용 필요' 안내와 설정 열기 버튼으로 처리하고, 상태는 `SMAppService.status`로 판단해요.
- 요청마다 `powermetrics`를 새로 띄우면 응답이 1.8초 걸려요. 앱이 값을 원하는 동안 보조 프로그램이 `powermetrics`를 1초 간격으로 계속 실행하고, 가장 최근 표본을 넘겨주는 방식을 검토해요. 이때 늘어나는 CPU 사용량은 실사용 점검에서 재요.
- Xcode에서 평소처럼 디버거를 붙여 ⌘R로 개발해도 돼요. 중단점을 쓴 뒤 보조 프로그램 연결이 끊기면 앱의 `CS_VALID`부터 확인해요.

### 확인 안 한 것

통합과 실사용 점검 때 확인해요.

- 서명이 다른 프로그램의 연결이 실제로 거절되는지
- 중단점에 멈췄다가 다시 간 뒤의 연결
- 등록 해제 뒤 보조 프로그램 프로세스가 실제로 끝났는지(이번에는 등록 상태 값만 확인)
- 재부팅 뒤 허용 유지, 빌드 폴더가 바뀌거나 앱을 옮겼을 때의 등록 상태
