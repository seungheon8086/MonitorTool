// 디스크 활성 시간 엔진 1: 커널 추적(kdebug) 제어와 이벤트 해석. (docs/DISK_ACTIVE_TIME.md)
// Diagnostics/DiskActiveProbe/Sources/Kdebug.swift에서 옮겼다. 규칙은 그대로이고, 도구에서만 쓰던 상수와 칸은 뺐다.
// 상수와 배치는 XNU xnu-12377.1.9의 sys/sysctl.h, sys/kdebug.h, sys/kdebug_private.h(비공개 정의)에서 옮겼다.
// root가 필요하다. 소유자가 없거나 배경 도구(tailspind)만 있으면 가져오고, 다른 프로세스가 쥐고 있으면 EBUSY (kern_ktrace.c).
import Darwin

enum KD {
    // sysctl 이름: CTL_KERN > KERN_KDEBUG(24) > 명령 [> 값]
    static let kernKdebug: Int32 = 24
    static let opClearFlags: Int32 = 2      // KERN_KDDFLAGS: 값 = 끌 사용자 플래그
    static let opEnable: Int32 = 3          // KERN_KDENABLE: 값 1 켬, 0 끔
    static let opSetBuf: Int32 = 4          // KERN_KDSETBUF: 값 = 이벤트 수 (커널이 최솟값으로 올림)
    static let opGetBuf: Int32 = 5          // KERN_KDGETBUF: kbufinfo_t (읽기만, root면 소유자가 아니어도 됨)
    static let opSetup: Int32 = 6           // KERN_KDSETUP: 버퍼 만들기
    static let opRemove: Int32 = 7          // KERN_KDREMOVE: 해제 (배경 도구에 알려 자리를 돌려줌)
    static let opReadTrace: Int32 = 10      // KERN_KDREADTR: 넣을 때 바이트, 나올 때 이벤트 수
    static let opSetTypeFilter: Int32 = 22  // KERN_KDSET_TYPEFILTER: 8 KiB 비트맵 (class<<8|subclass마다 1비트)
    static let opBufWait: Int32 = 23        // KERN_KDBUFWAIT: 길이 자리에 기다릴 ms, 나올 때 기준치를 넘었으면 1 (소유자만)

    static let enableTrace: Int32 = 1       // KDEBUG_ENABLE_TRACE
    static let typeFilterSize = 8192        // KDBG_TYPEFILTER_BITMAP_SIZE
    static let eventSize = 64               // sizeof(kd_buf), arm64

    // kbufinfo_t.flags
    static let flagNoWrap: UInt32 = 0x0000_0002      // KDBG_NOWRAP: 버퍼가 차면 기록을 멈춤
    static let flagContinuous: UInt32 = 0x0000_0200  // KDBG_CONTINUOUS_TIME: 시각이 mach_continuous_time
    static let flagMatchDisable: UInt32 = 0x0000_0800 // KDBG_MATCH_DISABLE: 특정 이벤트에서 기록을 멈춤
    static let flagBufInit: UInt32 = 0x8000_0000     // KDBG_BUFINIT

    // 이벤트 종류 = debugid >> 16 (class << 8 | subclass)
    static let cscDiskIO: UInt32 = 0x0302            // DBG_FSYSTEM(3) / DBG_DKRW(2)
    static let cscIoctl: UInt32 = 0x0306             // DBG_FSYSTEM(3) / DBG_IOCTL(6)
    static let lostEvents: UInt32 = 0x0702_0008      // TRACE_LOST_EVENTS = DBG_TRACE(7) / DBG_TRACE_INFO(2) / 2
    static let cscSSD: UInt32 = 0x0615               // DBG_DRIVERS(6) / DBG_SSD(21), Apple SSD 드라이버 (뜻은 도구 1단계 관찰로 정함)

    // eventID (함수 비트를 뺀 debugid)
    static let syncRequest: UInt32 = 0x0306_0000     // 동기화 요청 DKIOCSYNCHRONIZE: 인자 1 장치, 2 명령, 3 옵션 (2 = 장벽). 한 번 찍힘
    static let ssdFlush: UInt32 = 0x0615_4008        // 캐시 비우기: 시작(함수 1)·끝(함수 2), 같은 스레드
    static let ssdTrim: UInt32 = 0x0615_400c         // TRIM 명령: 시작·끝, 같은 스레드

    // DBG_TRACE: 형식 필터와 상관없이 늘 들어온다 (kdebug.c). 프로그램 실행 때 같은 스레드에서 둘이 이어서 찍힌다
    static let execData: UInt32 = 0x0700_0008        // TRACE_DATA_EXEC: 인자 1 pid
    static let execString: UInt32 = 0x0701_0008      // TRACE_STRING_EXEC: 인자 1~4에 프로세스 이름 32바이트

    // DKIO_*: debugid의 code 칸 = (debugid >> 2) & 0x3fff
    static let dkioDone: UInt32 = 0x01

    static let funcStart: UInt32 = 1        // DBG_FUNC_START
    static let funcEnd: UInt32 = 2          // DBG_FUNC_END
}

/// kbufinfo_t: nkdbufs, nolog, flags, nkdthreads, bufid (int 5개, 20바이트)
struct KBufInfo {
    var recordingOff: Bool
    var flags: UInt32
    var ownerPid: Int32            // -1이면 소유자 없음
}

/// kd_buf 하나 (64바이트: 시각 · 인자 1~4 · 스레드 ID · debugid · cpuid · 빈칸)
struct TraceEvent {
    var time: UInt64               // ns
    var debugid: UInt32
    var arg1: UInt64
    var arg2: UInt64
    var arg3: UInt64
    var arg4: UInt64
    var thread: UInt64

    var csc: UInt32 { debugid >> 16 }
    var eventID: UInt32 { debugid & 0xffff_fffc }
    var code: UInt32 { (debugid >> 2) & 0x3fff }
    var function: UInt32 { debugid & 3 }
}

struct KdebugError: Error, CustomStringConvertible {
    let step: String
    let code: Int32

    var description: String {
        let reason: String
        switch code {
        case EBUSY: reason = "다른 도구가 사용 중"
        case EPERM: reason = "권한 없음"
        case EINVAL: reason = "잘못된 값"
        case ENOMEM: reason = "메모리 부족"
        default: reason = String(cString: strerror(code))
        }
        return "\(step) 실패 · \(reason) (errno \(code))"
    }
}

/// mach 시각 ↔ ns. 추적 이벤트 시각은 기본이 mach_absolute_time이고, KDBG_CONTINUOUS_TIME이면 mach_continuous_time.
/// 켤 때 그 플래그를 끄고, 켠 뒤 플래그를 보고 continuous를 맞춘다. (추적 스레드만 바꾼다)
enum Timebase {
    static var continuous = false

    static let info: mach_timebase_info_data_t = {
        var i = mach_timebase_info_data_t()
        mach_timebase_info(&i)
        return i
    }()

    /// 넘치지 않게 128비트로 곱하고 나눈다 (이상한 시각 값이 와도 멈추지 않게)
    static func ns(_ ticks: UInt64) -> UInt64 {
        if info.numer == info.denom { return ticks }
        let wide = ticks.multipliedFullWidth(by: UInt64(info.numer))
        let denom = UInt64(info.denom)
        if wide.high >= denom { return UInt64.max }
        return denom.dividingFullWidth((high: wide.high, low: wide.low)).quotient
    }
    static func now() -> UInt64 { ns(continuous ? mach_continuous_time() : mach_absolute_time()) }
}

enum Kdebug {
    /// sysctl 한 번. 성공하면 0, 실패하면 errno.
    private static func call(_ op: Int32, value: Int32?, buffer: UnsafeMutableRawPointer?, length: inout Int) -> Int32 {
        var mib: [Int32] = [CTL_KERN, KD.kernKdebug, op]
        if let value { mib.append(value) }
        let count = u_int(mib.count)
        return sysctl(&mib, count, buffer, &length, nil, 0) == 0 ? 0 : errno
    }

    private static func simple(_ op: Int32, value: Int32?, step: String) throws {
        var length = 0
        let code = call(op, value: value, buffer: nil, length: &length)
        if code != 0 { throw KdebugError(step: step, code: code) }
    }

    /// 지금 상태 (읽기만)
    static func info() throws -> KBufInfo {
        var raw = [Int32](repeating: 0, count: 5)
        var length = 20
        let code = raw.withUnsafeMutableBytes { p in
            call(KD.opGetBuf, value: nil, buffer: p.baseAddress, length: &length)
        }
        if code != 0 { throw KdebugError(step: "상태 읽기", code: code) }
        return KBufInfo(recordingOff: raw[1] != 0, flags: UInt32(bitPattern: raw[2]), ownerPid: raw[4])
    }

    /// 첫 설정 명령이 소유권을 가져온다 (배경 도구의 설정은 커널이 초기화)
    static func setBuffer(events: Int32) throws { try simple(KD.opSetBuf, value: events, step: "버퍼 크기") }
    static func setup() throws { try simple(KD.opSetup, value: nil, step: "버퍼 만들기") }
    static func clearFlags(_ flags: UInt32) throws { try simple(KD.opClearFlags, value: Int32(bitPattern: flags), step: "플래그 끄기") }
    static func enable(_ on: Bool) throws { try simple(KD.opEnable, value: on ? KD.enableTrace : 0, step: on ? "기록 켜기" : "기록 끄기") }
    static func remove() throws { try simple(KD.opRemove, value: nil, step: "해제") }

    /// 버퍼가 기준치(저장 단위의 절반)만큼 차거나 timeoutMs가 지날 때까지 커널 안에서 잔다 (kdbg_wait).
    /// 기준치를 넘어서 깼으면 참. 신호가 오면 일찍 돌아올 수 있다. 기다리는 동안 커널은 ktrace 잠금을 풀어 둔다
    static func waitForBuffer(timeoutMs: Int) throws -> Bool {
        var length = max(timeoutMs, 1)
        let code = call(KD.opBufWait, value: nil, buffer: nil, length: &length)
        if code != 0 { throw KdebugError(step: "버퍼 기다리기", code: code) }
        return length != 0
    }

    /// 형식 필터: 주어진 종류(class<<8|subclass)만 기록한다. 커널은 DBG_TRACE를 늘 허용한다.
    static func setTypeFilter(_ kinds: [UInt32]) throws {
        var bitmap = [UInt8](repeating: 0, count: KD.typeFilterSize)
        for kind in kinds { bitmap[Int(kind >> 3)] |= UInt8(1) << (kind & 7) }
        var length = KD.typeFilterSize
        let code = bitmap.withUnsafeMutableBytes { p in
            call(KD.opSetTypeFilter, value: nil, buffer: p.baseAddress, length: &length)
        }
        if code != 0 { throw KdebugError(step: "형식 필터", code: code) }
    }
}

/// 쌓인 이벤트를 읽는다. 커널이 CPU별 버퍼를 시각 순서로 합쳐 준다.
final class TraceReader {
    let capacity: Int
    private let buffer: UnsafeMutableRawPointer

    init(capacity: Int) {
        self.capacity = capacity
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity * KD.eventSize, alignment: 16)
    }

    deinit { buffer.deallocate() }

    /// 읽은 이벤트를 body에 하나씩 넘기고, 읽은 수를 돌려준다.
    func read(_ body: (TraceEvent) -> Void) throws -> Int {
        var mib: [Int32] = [CTL_KERN, KD.kernKdebug, KD.opReadTrace]
        let count = u_int(mib.count)
        var length = capacity * KD.eventSize
        if sysctl(&mib, count, buffer, &length, nil, 0) != 0 {
            throw KdebugError(step: "읽기", code: errno)
        }
        let n = min(length, capacity)
        for i in 0..<n {
            let b = buffer + i * KD.eventSize
            body(TraceEvent(
                time: Timebase.ns(b.load(fromByteOffset: 0, as: UInt64.self)),
                debugid: b.load(fromByteOffset: 48, as: UInt32.self),
                arg1: b.load(fromByteOffset: 8, as: UInt64.self),
                arg2: b.load(fromByteOffset: 16, as: UInt64.self),
                arg3: b.load(fromByteOffset: 24, as: UInt64.self),
                arg4: b.load(fromByteOffset: 32, as: UInt64.self),
                thread: b.load(fromByteOffset: 40, as: UInt64.self)))
        }
        return n
    }
}
