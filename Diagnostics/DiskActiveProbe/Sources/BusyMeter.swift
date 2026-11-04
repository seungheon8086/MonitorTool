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
