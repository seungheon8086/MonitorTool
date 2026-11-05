// 디스크 활성 시간 엔진 3: 바쁜 시간 계산 (순수 값 타입). (docs/DISK_ACTIVE_TIME.md 1장)
// Diagnostics/DiskActiveProbe/Sources/BusyMeter.swift의 LayeredMeter를 옮겼다. 규칙은 그대로이고 도구 보고용 셈만 뺐다
// (규칙 검산: 도구 폴더의 busy_meter_test.py · layered_meter_test.py).
// 요청 표 하나로 층 셋을 함께 센다: 0 디스크 I/O만 ⊂ 1 + 캐시 비우기 ⊂ 2 + TRIM. 활성 시간은 층 2.
// 디스크마다 걸린 요청 수가 0→1이면 바쁨 시작, 1→0이면 바쁨 끝 (요청 구간의 합집합 길이).

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
            release(old.slot, level: 0, at: t)
        }
        acquire(s, level: 0, at: t)
    }

    /// 디스크 I/O 끝. 짝이 없으면(추적을 켜기 전에 시작한 요청 등) 넘긴다
    mutating func doneIO(key: UInt64, at t: UInt64) {
        guard let p = io.removeValue(forKey: key) else { return }
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
            release(p.slot, level: 0, at: t)
        }
        let oldCommands = commands.filter { t > $0.value.start && t - $0.value.start > limit }
        for (key, p) in oldCommands {
            commands.removeValue(forKey: key)
            release(p.slot, level: p.level, at: t)
        }
    }

    /// 시각 t까지의 누적 바쁜 시간 (진행 중 구간 포함). 층 m = 0 디스크 I/O만 · 1 + 캐시 비우기 · 2 + TRIM
    func busyNs(slot s: Int, meter m: Int, at t: UInt64) -> UInt64 {
        let i = s * LayeredMeter.levels + m
        let extra: UInt64 = (inFlight[i] > 0 && t > busySince[i]) ? t - busySince[i] : 0
        return accumulated[i] + extra
    }
}
