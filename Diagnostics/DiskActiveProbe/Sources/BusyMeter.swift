// DiskActiveProbe 엔진 조각 3: 바쁜 시간 계산 (순수 값 타입).
// 디스크마다 걸린 요청 수가 0→1이 되면 바쁨 시작, 1→0이 되면 바쁨 끝. 끝난 바쁜 구간의 길이를 더한다.
// 활성 % = (구간 끝의 누적 − 구간 처음의 누적) ÷ 구간 길이. Windows 작업 관리자의 활성 시간과 같은 뜻.
// 이벤트는 시각 순서대로 넣는다. 시각 단위는 ns. 규칙은 busy_meter_test.py와 한 줄씩 같다.

struct BusyMeter {
    struct DiskState {
        var inFlight = 0
        var busySince: UInt64 = 0
        var busyNs: UInt64 = 0
        var completed: UInt64 = 0
        var bytes: UInt64 = 0
    }

    struct Pending {
        var disk: UInt64
        var start: UInt64
        var bytes: UInt64
    }

    private(set) var disks: [UInt64: DiskState] = [:]
    private var pending: [UInt64: Pending] = [:]
    /// 시작을 못 본 끝 (추적을 켜기 전에 시작한 요청 등)
    private(set) var unmatchedDone: UInt64 = 0
    /// 끝을 못 보고 같은 열쇠로 다시 시작한 요청
    private(set) var replacedStart: UInt64 = 0
    /// 잃은 이벤트·기한 초과로 버린 요청
    private(set) var dropped: UInt64 = 0
    /// 잃은 이벤트 표시를 받은 횟수
    private(set) var lossCount: UInt64 = 0

    var pendingCount: Int { pending.count }

    /// 요청 시작. key = 이벤트 인자 1 (버퍼 주소를 섞은 값, 원시 장치는 스레드 ID)
    mutating func start(key: UInt64, disk: UInt64, bytes: UInt64, at t: UInt64) {
        if let old = pending.removeValue(forKey: key) {
            replacedStart += 1
            release(disk: old.disk, at: t)
        }
        var d = disks[disk] ?? DiskState()
        if d.inFlight == 0 { d.busySince = t }
        d.inFlight += 1
        disks[disk] = d
        pending[key] = Pending(disk: disk, start: t, bytes: bytes)
    }

    /// 요청 끝. 짝이 있으면 (디스크, 걸린 시간)을 돌려준다.
    mutating func done(key: UInt64, at t: UInt64) -> (disk: UInt64, duration: UInt64)? {
        guard let p = pending.removeValue(forKey: key) else {
            unmatchedDone += 1
            return nil
        }
        release(disk: p.disk, at: t)
        if var d = disks[p.disk] {
            d.completed += 1
            d.bytes += p.bytes
            disks[p.disk] = d
        }
        return (p.disk, t > p.start ? t - p.start : 0)
    }

    private mutating func release(disk: UInt64, at t: UInt64) {
        guard var d = disks[disk], d.inFlight > 0 else { return }
        d.inFlight -= 1
        if d.inFlight == 0 && t > d.busySince { d.busyNs += t - d.busySince }
        disks[disk] = d
    }

    /// 잃은 이벤트: 걸려 있던 요청을 모두 버리고 바쁜 구간을 t에서 닫는다 (그 구간은 '일부 누락')
    mutating func lose(at t: UInt64) {
        lossCount += 1
        dropped += UInt64(pending.count)
        pending.removeAll()
        for key in Array(disks.keys) {
            guard var d = disks[key], d.inFlight > 0 else { continue }
            if t > d.busySince { d.busyNs += t - d.busySince }
            d.inFlight = 0
            disks[key] = d
        }
    }

    /// limit(ns)보다 오래 끝나지 않은 요청을 버린다 (끝 이벤트를 잃은 것으로 본다)
    mutating func expire(olderThan limit: UInt64, at t: UInt64) {
        let old = pending.filter { t > $0.value.start && t - $0.value.start > limit }
        for (key, p) in old {
            pending.removeValue(forKey: key)
            dropped += 1
            release(disk: p.disk, at: t)
        }
    }

    /// 시각 t까지의 누적 바쁜 시간 (진행 중 구간 포함). t 이전 이벤트를 모두 넣은 뒤에 부른다.
    func busyNs(disk: UInt64, at t: UInt64) -> UInt64 {
        guard let d = disks[disk] else { return 0 }
        let extra: UInt64 = (d.inFlight > 0 && t > d.busySince) ? t - d.busySince : 0
        return d.busyNs + extra
    }
}

/// 바쁜 시간 세 가지를 요청 표 하나로 함께 센다 (4단계 가볍게 하기, BusyMeter 셋과 같은 값 · layered_meter_test.py로 검산).
/// 층 0 = 디스크 I/O, 층 1 = 캐시 비우기, 층 2 = TRIM. 층 L인 요청은 계산기 L…2에 함께 들어간다:
///   계산기 0 = 디스크 I/O만 · 1 = + 캐시 비우기 · 2 = + TRIM (모두 요청 구간의 합집합)
/// 디스크 상태는 자리 번호로 배열에 두고 요청에 자리를 적어 둔다. 디스크 I/O 하나(시작·끝)에 사전 조회가 두 번이면 된다
/// (BusyMeter 셋은 요청 표 셋과 디스크 사전 셋을 따로 찾아서 스물 번이 넘었다)
struct LayeredMeter {
    static let levels = 3

    private struct IOPending {
        var slot: Int
        var start: UInt64
        var bytes: UInt64
    }

    private struct CommandPending {
        var slot: Int
        var start: UInt64
        var level: Int
    }

    /// 자리 → 디스크 ID
    private(set) var ids: [UInt64] = []
    private var slots: [UInt64: Int] = [:]
    // 자리 × 층 (자리 s의 층 m은 s * 3 + m)
    private var inFlight: [Int] = []
    private var busySince: [UInt64] = []
    private var accumulated: [UInt64] = []
    /// 자리마다 끝난 디스크 I/O 수와 바이트 (층 0만)
    private(set) var completed: [UInt64] = []
    private(set) var bytes: [UInt64] = []
    private var io: [UInt64: IOPending] = [:]
    private var commands: [UInt64: CommandPending] = [:]
    /// 아래 넷은 디스크 I/O(층 0) 요청만 센다 (BusyMeter 하나와 같은 뜻)
    private(set) var unmatchedDone: UInt64 = 0
    private(set) var replacedStart: UInt64 = 0
    private(set) var dropped: UInt64 = 0
    private(set) var lossCount: UInt64 = 0

    var pendingCount: Int { io.count + commands.count }

    /// 디스크의 자리 (처음 보면 만든다)
    mutating func slot(for disk: UInt64) -> Int {
        if let s = slots[disk] { return s }
        let s = ids.count
        ids.append(disk)
        slots[disk] = s
        inFlight.append(contentsOf: [0, 0, 0])
        busySince.append(contentsOf: [0, 0, 0])
        accumulated.append(contentsOf: [0, 0, 0])
        completed.append(0)
        bytes.append(0)
        return s
    }

    private mutating func acquire(_ s: Int, level: Int, at t: UInt64) {
        for m in level..<LayeredMeter.levels {
            let i = s * LayeredMeter.levels + m
            if inFlight[i] == 0 { busySince[i] = t }
            inFlight[i] += 1
        }
    }

    private mutating func release(_ s: Int, level: Int, at t: UInt64) {
        for m in level..<LayeredMeter.levels {
            let i = s * LayeredMeter.levels + m
            guard inFlight[i] > 0 else { continue }
            inFlight[i] -= 1
            if inFlight[i] == 0 && t > busySince[i] { accumulated[i] += t - busySince[i] }
        }
    }

    /// 디스크 I/O 시작 (층 0). key = 이벤트 인자 1. 끝을 못 본 같은 열쇠가 있으면 그 요청을 지금 닫는다
    mutating func startIO(key: UInt64, slot s: Int, bytes n: UInt64, at t: UInt64) {
        if let old = io.updateValue(IOPending(slot: s, start: t, bytes: n), forKey: key) {
            replacedStart += 1
            release(old.slot, level: 0, at: t)
        }
        acquire(s, level: 0, at: t)
    }

    /// 디스크 I/O 끝. 짝이 없으면(추적을 켜기 전에 시작한 요청 등) 세기만 한다
    mutating func doneIO(key: UInt64, at t: UInt64) {
        guard let p = io.removeValue(forKey: key) else {
            unmatchedDone += 1
            return
        }
        release(p.slot, level: 0, at: t)
        completed[p.slot] += 1
        bytes[p.slot] += p.bytes
    }

    /// 캐시 비우기(층 1)·TRIM(층 2) 시작. key는 디스크 I/O 열쇠와 겹치지 않게 태그를 붙인 값
    mutating func startCommand(key: UInt64, slot s: Int, level: Int, at t: UInt64) {
        if let old = commands.updateValue(CommandPending(slot: s, start: t, level: level), forKey: key) {
            release(old.slot, level: old.level, at: t)
        }
        acquire(s, level: level, at: t)
    }

    mutating func doneCommand(key: UInt64, at t: UInt64) {
        guard let p = commands.removeValue(forKey: key) else { return }
        release(p.slot, level: p.level, at: t)
    }

    /// 잃은 이벤트: 걸려 있던 요청을 모두 버리고 바쁜 구간을 t에서 닫는다
    mutating func lose(at t: UInt64) {
        lossCount += 1
        dropped += UInt64(io.count)
        io.removeAll()
        commands.removeAll()
        for i in 0..<inFlight.count where inFlight[i] > 0 {
            if t > busySince[i] { accumulated[i] += t - busySince[i] }
            inFlight[i] = 0
        }
    }

    /// limit(ns)보다 오래 끝나지 않은 요청을 버린다 (끝 이벤트를 잃은 것으로 본다)
    mutating func expire(olderThan limit: UInt64, at t: UInt64) {
        let oldIO = io.filter { t > $0.value.start && t - $0.value.start > limit }
        for (key, p) in oldIO {
            io.removeValue(forKey: key)
            dropped += 1
            release(p.slot, level: 0, at: t)
        }
        let oldCommands = commands.filter { t > $0.value.start && t - $0.value.start > limit }
        for (key, p) in oldCommands {
            commands.removeValue(forKey: key)
            release(p.slot, level: p.level, at: t)
        }
    }

    /// 시각 t까지의 누적 바쁜 시간 (진행 중 구간 포함). 계산기 m = 0 디스크 I/O만 · 1 + 캐시 비우기 · 2 + TRIM
    func busyNs(slot s: Int, meter m: Int, at t: UInt64) -> UInt64 {
        let i = s * LayeredMeter.levels + m
        let extra: UInt64 = (inFlight[i] > 0 && t > busySince[i]) ? t - busySince[i] : 0
        return accumulated[i] + extra
    }
}
