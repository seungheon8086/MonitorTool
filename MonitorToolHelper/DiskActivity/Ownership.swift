// 디스크 활성 시간 엔진 5: 추적 자리(ktrace 소유권). 상태 읽기, 얻기(남은 추적 정리), 내려놓기. (docs/DISK_ACTIVE_TIME.md 3.3)
// Diagnostics/DiskActiveProbe/Sources/Ownership.swift에서 옮겼다. 규칙은 XNU kern_ktrace.c·kdebug.c에서 읽었다.
// - 살아 있는 전경 소유자가 있으면 다른 프로세스의 kdebug 설정과 읽기(KDREADTR)는 모두 EBUSY. 상태 읽기(KDGETBUF)만 root면 된다
// - 소유자가 없거나 배경 도구(tailspind)만 있으면 root는 가져올 수 있다. 배경에서 가져오면 배경 도구의 설정은 커널이 지운다
// - 소유자가 죽어도 기록은 계속된다. 그다음 설정하는 root 프로세스가 가져간다
// - kperf.blessed_preempt가 1이면 root가 kperf로 소유자를 바꿀 수 있다(Instruments 호환용). 그때 우리 읽기는 EBUSY가 된다
import Darwin

/// sysctl ktrace.* (누구나 읽기만)
struct KtraceState {
    var state: Int32            // 0 꺼짐 · 1 전경 · 2 배경
    var owningPid: Int32        // 커널 변수 그대로라 끝난 프로세스일 수 있다 (KDGETBUF가 정리하기 전)
    var configuredBy: String    // 마지막으로 설정한 프로세스 이름

    static func read() -> KtraceState {
        KtraceState(state: sysctlInt32("ktrace.state") ?? -1,
                    owningPid: sysctlInt32("ktrace.owning_pid") ?? 0,
                    configuredBy: sysctlString("ktrace.configured_by"))
    }

    var stateName: String {
        switch state {
        case 0: return "꺼짐"
        case 1: return "전경"
        case 2: return "배경"
        default: return "알 수 없음(\(state))"
        }
    }
}

func sysctlInt32(_ name: String) -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buf = [CChar](repeating: 0, count: size + 1)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// 추적 자리를 쥔 프로세스 이름. pid로 못 찾으면 마지막으로 설정한 프로세스 이름
func ownerName(_ pid: Int32, _ k: KtraceState) -> String {
    if pid > 0, let name = processName(pid) { return name }
    return k.configuredBy.isEmpty || k.configuredBy == "?" ? "알 수 없음" : k.configuredBy
}

enum AcquireResult {
    case acquired(cleaned: Bool)    // cleaned: 소유자 없이 남은 추적을 먼저 정리함
    case busy(owner: String)        // 살아 있는 다른 도구가 쓰는 중이라 손대지 않음
    case failed(String)
}

/// 추적 자리를 얻고 기록을 켠다. filter는 형식 필터를 거는 일 (버퍼를 만든 뒤 부른다).
/// 남은 사용자 플래그(멈춤·연속 시각·특정 이벤트에서 멈춤)는 끈다.
func acquireTrace(events: Int32, filter: () throws -> Void) -> AcquireResult {
    var cleaned = false
    if let info = try? Kdebug.info() {
        let k = KtraceState.read()
        if info.ownerPid > 0 && info.ownerPid != getpid() && k.state == 1 {
            return .busy(owner: ownerName(info.ownerPid, k))
        }
        if info.ownerPid <= 0 && info.flags & KD.flagBufInit != 0 {
            // 소유자가 죽고 남은 추적 (우리 것이든 다른 도구 것이든): 끄고 해제한 뒤 새로 켠다
            try? Kdebug.enable(false)
            try? Kdebug.remove()
            cleaned = true
        }
    }
    var owning = false
    do {
        try Kdebug.setBuffer(events: events)
        owning = true
        try Kdebug.clearFlags(KD.flagNoWrap | KD.flagContinuous | KD.flagMatchDisable)
        try Kdebug.setup()
        try filter()
        try Kdebug.enable(true)
    } catch let error as KdebugError where error.code == EBUSY && !owning {
        let k = KtraceState.read()
        return .busy(owner: ownerName(k.owningPid, k))
    } catch {
        if owning { try? Kdebug.remove() }
        return .failed("\(error)")
    }
    if let i = try? Kdebug.info() {
        Timebase.continuous = i.flags & KD.flagContinuous != 0
    }
    return .acquired(cleaned: cleaned)
}

/// 기록을 끄고 해제한다. 문제가 있으면 그 글 (내가 소유자가 아니면 EBUSY)
func releaseTrace() -> String? {
    var problem: String?
    do { try Kdebug.enable(false) } catch { problem = "\(error)" }
    do { try Kdebug.remove() } catch { problem = "\(error)" }
    return problem
}

/// 내가 소유자일 때만 놓는다 (소유자가 없거나 남의 것이면 손대지 않음: 배경 도구에서 자리를 뺏지 않게)
func releaseTraceIfMine() -> String? {
    guard let info = try? Kdebug.info(), info.ownerPid == getpid() else { return nil }
    return releaseTrace()
}
