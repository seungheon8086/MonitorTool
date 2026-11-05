// 디스크 활성 시간 엔진 4: 이벤트를 읽는 대로 시각 순서대로 처리하고, 정한 시각(1초 경계)의 디스크별 누적값을 만든다.
// (docs/DISK_ACTIVE_TIME.md 3장) Diagnostics/DiskActiveProbe/Sources/Engine.swift에서 옮겼다.
// 규칙(쓰지 않는 SSD 이벤트는 읽을 때 버리기 · 순서가 섞이면 뒤쪽만 다시 줄 세우기 · 몰림 뒤 대기열 줄이기 ·
// 30초 넘게 끝나지 않은 요청 버리기 · 잃음 처리)은 그대로이고, 도구가 보고하려고 세던 값만 뺐다 (규칙 검산: engine_test.py).
// 활성 시간 = 디스크 I/O ∪ 캐시 비우기(내장 SSD) ∪ TRIM(내장 SSD) = LayeredMeter의 층 2.
import Foundation

/// 한 디스크의 누적값 (어느 시각 기준)
struct DiskTotals {
    var active: UInt64 = 0          // 활성 시간 (ns). SSD 드라이버 이벤트가 없는 디스크는 디스크 I/O만
    var ops: UInt64 = 0             // 끝까지 본 디스크 I/O 작업 수
    var bytes: UInt64 = 0
}

/// 추적 이벤트로 본 프로그램 실행
struct ExecEvent {
    let time: UInt64
    let pid: Int32
    let name: String
}

final class Engine {
    private var map: DiskMap
    private var mapBuiltAt: UInt64
    private let reader: TraceReader
    private var meter = LayeredMeter()
    private var deviceSlots: [Int32: Int] = [:]     // 장치 번호 → 계산기 자리 (디스크 목록에 있는 장치만)
    private var ssdDisk: UInt64?                     // 내장 SSD (Apple Fabric). 디스크 목록이 바뀔 때만 다시 찾는다
    private var ssdSlot: Int?
    private var pending: [TraceEvent] = []
    private var tickTimes: [UInt64] = []
    private var execPid: [UInt64: Int32] = [:]
    private static let flushKey: UInt64 = 0x8000_0000_0000_0000
    private static let trimKey: UInt64 = 0x4000_0000_0000_0000

    /// 커널 버퍼가 넘쳐 이벤트를 잃은 횟수 (TRACE_LOST_EVENTS)
    private(set) var losses: UInt64 = 0
    private var flushStarts = 0
    private var fullSyncsInternal = 0               // 내장 SSD로 간 전체 동기화 요청 (옵션 0)
    private var unknownSinceRefresh = 0
    private let ssdEvents: Bool
    /// 참이면 프로그램 실행 이벤트를 모은다 (takeExecs로 꺼낸다)
    var watchExecs = false
    private var execs: [ExecEvent] = []

    /// map: 쓸 디스크 목록. ssdEvents: 형식 필터에 SSD 드라이버 이벤트를 넣었는지.
    /// capacity: 한 번에 읽는 이벤트 수 (65,536개 = 4 MiB)
    init(map: DiskMap, ssdEvents: Bool, capacity: Int = 65_536) {
        reader = TraceReader(capacity: capacity)
        self.map = map
        mapBuiltAt = Timebase.now()
        ssdDisk = map.internalSSD
        self.ssdEvents = ssdEvents
    }

    /// 내장 SSD의 캐시 비우기·TRIM 이벤트를 받는지 (DiskActivitySample.flushTrim).
    /// 전체 동기화 요청은 오는데 캐시 비우기 이벤트가 하나도 없으면, 이 macOS에서는 SSD 이벤트의 뜻이 바뀐 것으로 본다.
    /// 그래도 활성 시간은 디스크 I/O만으로 맞게 나온다 (캐시 비우기 몫이 0이 될 뿐)
    var flushTrimSeen: Bool {
        ssdEvents && !(fullSyncsInternal >= 5 && flushStarts == 0)
    }

    /// 받는 종류: 디스크 I/O·디스크 명령은 늘, SSD 드라이버 이벤트는 ssd가 참일 때만 (DBG_TRACE는 커널이 늘 넣는다)
    static func kinds(ssd: Bool) -> [UInt32] {
        ssd ? [KD.cscDiskIO, KD.cscIoctl, KD.cscSSD] : [KD.cscDiskIO, KD.cscIoctl]
    }

    /// 새 디스크 목록을 쓴다 (추적 서비스가 바뀐 것을 알아채고 넘겨준다). 장치 → 자리 기억은 지운다
    func useMap(_ newMap: DiskMap) {
        map = newMap
        mapBuiltAt = Timebase.now()
        unknownSinceRefresh = 0
        deviceSlots.removeAll()
        ssdDisk = newMap.internalSSD
        ssdSlot = nil
    }

    /// 디스크 구성이 그대로라 목록을 다시 만들지 않았을 때: 모르는 장치 셈을 처음부터 (2초마다 다시 보지 않게)
    func acknowledgeUnknown() {
        unknownSinceRefresh = 0
        mapBuiltAt = Timebase.now()
    }

    /// 모르는 장치가 보였고 목록을 만든 지 2초가 지났으면 참 (꽂은 디스크)
    func wantsNewMap(at now: UInt64) -> Bool {
        unknownSinceRefresh > 0 && minus(now, mapBuiltAt) > 2_000_000_000
    }

    /// 쌓인 이벤트를 읽어 처리 대기열에 바로 붙인다 (다 비울 때까지). 소유권을 잃었으면 EBUSY로 던진다.
    /// SSD 드라이버 이벤트는 캐시 비우기·TRIM만 남긴다 (무거운 부하에서 이벤트의 약 60%가 명령마다 찍히는 SSD 이벤트)
    func read() throws {
        var execData: [(thread: UInt64, pid: Int32)] = []
        var execNames: [(time: UInt64, thread: UInt64, name: String)] = []
        let watch = watchExecs
        let start = pending.count
        var last = pending.last?.time ?? 0
        var inOrder = true
        var oldest = UInt64.max                 // 이번에 붙인 것 중 가장 이른 시각
        // 대기열을 잠시 지역 변수로 옮겨 붙인다 (이벤트마다 클래스 속성에 접근하지 않게, 복사는 없음)
        var queue: [TraceEvent] = []
        swap(&queue, &pending)
        var failure: Error?
        do {
            while true {
                let n = try reader.read { e in
                    let keep = e.csc == KD.cscDiskIO || e.csc == KD.cscIoctl || e.eventID == KD.lostEvents
                        || (e.csc == KD.cscSSD && (e.eventID == KD.ssdFlush || e.eventID == KD.ssdTrim))
                    if keep {
                        if e.time < last { inOrder = false } else { last = e.time }
                        if e.time < oldest { oldest = e.time }
                        queue.append(e)
                    } else if watch && e.debugid == KD.execData {
                        execData.append((thread: e.thread, pid: Int32(truncatingIfNeeded: e.arg1)))
                    } else if watch && e.debugid == KD.execString {
                        execNames.append((time: e.time, thread: e.thread, name: Engine.execName(e)))
                    }
                }
                if n < reader.capacity { break }
            }
        } catch {
            failure = error             // 읽은 만큼은 대기열에 두고 던진다
        }
        swap(&queue, &pending)
        if !inOrder { reorder(from: start, oldest: oldest) }
        if let f = failure { throw f }
        // 실행 이벤트: 같은 스레드의 pid(먼저 찍힘)와 이름을 잇는다
        for d in execData { execPid[d.thread] = d.pid }
        for x in execNames {
            let pid = execPid.removeValue(forKey: x.thread) ?? -1
            execs.append(ExecEvent(time: x.time, pid: pid, name: x.name))
        }
    }

    /// 모은 프로그램 실행을 꺼낸다
    func takeExecs() -> [ExecEvent] {
        let out = execs
        execs.removeAll()
        return out
    }

    /// TRACE_STRING_EXEC의 인자 1~4(8바이트씩, 리틀 엔디언)에 든 프로세스 이름
    static func execName(_ e: TraceEvent) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for v in [e.arg1, e.arg2, e.arg3, e.arg4] {
            for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(i * 8))) }
        }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// 앞선 시각의 이벤트가 늦게 왔으면 그 시각 뒤쪽만 다시 줄 세운다 (같은 시각이면 먼저 온 순서).
    /// 대기열의 start 앞부분은 이미 시각 순이므로, oldest보다 늦은 첫 자리부터 끝까지만 정렬한다 (engine_test.py로 검산)
    private func reorder(from start: Int, oldest: UInt64) {
        var lo = 0
        var hi = start
        while lo < hi {
            let mid = (lo + hi) / 2
            if pending[mid].time <= oldest { lo = mid + 1 } else { hi = mid }
        }
        let tail = pending[lo...].enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }.map { $0.element }
        pending.replaceSubrange(lo..., with: tail)
    }

    /// 경계 시각을 더한다 (그 시각의 누적값을 process가 돌려준다)
    func addTick(_ time: UInt64) {
        tickTimes.append(time)
    }

    /// cutoff까지의 이벤트와 경계 시각을 시각 순서대로 처리한다. 지난 경계 시각마다 누적값을 돌려준다.
    func process(until cutoff: UInt64) -> [(time: UInt64, totals: [UInt64: DiskTotals])] {
        var out: [(time: UInt64, totals: [UInt64: DiskTotals])] = []
        var used = 0
        for e in pending {
            if e.time > cutoff { break }
            while let t = tickTimes.first, t < e.time {
                tickTimes.removeFirst()
                out.append((time: t, totals: snapshot(at: t)))
            }
            handle(e)
            used += 1
        }
        if used > 0 { pending.removeFirst(used) }
        // 몰림 뒤에 큰 용량이 남지 않게 줄인다 (도구 밤새 기록: 몰림 뒤 메모리가 18~21 MB에 머묾)
        if pending.capacity > 65_536 && pending.count < pending.capacity / 8 {
            var fresh: [TraceEvent] = []
            fresh.reserveCapacity(max(pending.count * 2, 4_096))
            fresh.append(contentsOf: pending)
            pending = fresh
        }
        while let t = tickTimes.first, t <= cutoff {
            tickTimes.removeFirst()
            out.append((time: t, totals: snapshot(at: t)))
        }
        return out
    }

    private func snapshot(at t: UInt64) -> [UInt64: DiskTotals] {
        // 30초 넘게 끝나지 않은 요청은 끝 이벤트를 잃은 것으로 본다
        meter.expire(olderThan: 30_000_000_000, at: t)
        var out: [UInt64: DiskTotals] = [:]
        // 요청이 한 번이라도 있었던 디스크 모두 (캐시 비우기만 있던 디스크도)
        for (s, id) in meter.ids.enumerated() {
            out[id] = DiskTotals(active: meter.busyNs(slot: s, meter: 2, at: t),
                                 ops: meter.completed[s], bytes: meter.bytes[s])
        }
        return out
    }

    /// 장치 번호 → 계산기 자리. 디스크 목록에 있는 장치만 기억한다 (모르는 장치·디스크가 아닌 장치는 매번 세도록)
    private func slot(forDevice dev: Int32) -> Int {
        if let s = deviceSlots[dev] { return s }
        let disk = diskID(for: dev)
        let s = meter.slot(for: disk)
        if map.devices[dev] != nil { deviceSlots[dev] = s }
        return s
    }

    /// 내장 SSD의 자리 (캐시 비우기·TRIM이 처음 시작할 때 만든다: 그것만 있던 디스크도 누적값에 나온다)
    private func internalSSDSlot() -> Int? {
        if let s = ssdSlot { return s }
        guard let id = ssdDisk else { return nil }
        let s = meter.slot(for: id)
        ssdSlot = s
        return s
    }

    /// 모르는 장치·디스크가 아닌 장치(/dev/null 등)는 ID 0으로 모은다 (앱에 넘기는 물리 디스크 목록에는 없다)
    private func diskID(for dev: Int32) -> UInt64 {
        if let entry = map.devices[dev] { return entry.disk ?? 0 }
        if !DiskMap.isNonDisk(dev) { unknownSinceRefresh += 1 }
        return 0
    }

    private func handle(_ e: TraceEvent) {
        if e.csc == KD.cscDiskIO {
            if e.code & KD.dkioDone == 0 {
                meter.startIO(key: e.arg1, slot: slot(forDevice: Int32(truncatingIfNeeded: e.arg2)), bytes: e.arg4, at: e.time)
            } else {
                meter.doneIO(key: e.arg1, at: e.time)
            }
        } else if e.csc == KD.cscIoctl {
            if e.eventID == KD.syncRequest && e.function == 0 && e.arg3 == 0, let ssd = ssdDisk,
               map.devices[Int32(truncatingIfNeeded: e.arg1)]?.disk == ssd {
                fullSyncsInternal += 1
            }
        } else if e.csc == KD.cscSSD {
            guard ssdDisk != nil else { return }
            if e.eventID == KD.ssdFlush {
                let key = Engine.flushKey | e.thread
                if e.function == KD.funcStart {
                    flushStarts += 1
                    if let ssd = internalSSDSlot() { meter.startCommand(key: key, slot: ssd, level: 1, at: e.time) }
                } else if e.function == KD.funcEnd {
                    meter.doneCommand(key: key, at: e.time)
                }
            } else if e.eventID == KD.ssdTrim {
                let key = Engine.trimKey | e.thread
                if e.function == KD.funcStart {
                    if let ssd = internalSSDSlot() { meter.startCommand(key: key, slot: ssd, level: 2, at: e.time) }
                } else if e.function == KD.funcEnd {
                    meter.doneCommand(key: key, at: e.time)
                }
            }
        } else if e.eventID == KD.lostEvents {
            losses += 1
            meter.lose(at: e.time)
        }
    }
}

/// 음수가 될 수 있는 차이는 0으로 (UInt64 뺄셈이 넘치면 멈추므로)
func minus(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }
