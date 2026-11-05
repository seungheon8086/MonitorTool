// 엔진: 이벤트를 읽는 대로 시각 순서대로 처리하고, 정한 시각(1초마다)의 디스크별 누적값을 만든다.
// 나중에 보조 프로그램으로 옮길 부분이다. 1초 표본 계산과 보고는 Session(Stage2.swift)·Holder(Stage3.swift)가 한다.
// 바쁜 시간은 셋을 함께 센다 (모두 요청 구간의 합집합, LayeredMeter 하나로):
//   디스크 I/O만 ⊂ + 캐시 비우기(내장 SSD) ⊂ + TRIM(내장 SSD). 활성 %는 가장 넓은 것 (캐시 비우기 2026-11-04, TRIM 2026-11-05 결정).
// 4단계 가볍게 하기: 쓰지 않는 SSD 이벤트(명령마다 찍히는 것)는 읽을 때 버리고, 읽은 이벤트는 대기열에 바로 붙이며
// 순서가 섞이면 뒤쪽만 다시 줄 세운다. 몰림 뒤에는 대기열 용량을 줄인다. 디스크 목록은 hold가 만들어 넘겨줄 수 있다.
import Foundation

/// 한 디스크의 누적값 (어느 시각 기준)
struct DiskTotals {
    var busy: UInt64 = 0            // 디스크 I/O 요청이 하나라도 걸려 있던 시간 (ns)
    var busyWithFlush: UInt64 = 0   // + 캐시 비우기. SSD 이벤트를 받지 않으면 busy와 같다
    var busyWithTrim: UInt64 = 0    // + 캐시 비우기 + TRIM = 활성 시간 (2026-11-05 결정)
    var ops: UInt64 = 0
    var bytes: UInt64 = 0
}

/// 추적 이벤트로 본 프로그램 실행
struct ExecEvent {
    let time: UInt64
    let pid: Int32
    let name: String
}

final class Engine {
    private(set) var map: DiskMap
    private var mapBuiltAt: UInt64
    private let reader: TraceReader
    private var meter = LayeredMeter()
    private var deviceSlots: [Int32: Int] = [:]     // 장치 번호 → 계산기 자리 (디스크 목록에 있는 장치만)
    private var ssdDisk: UInt64?                     // 내장 SSD (Apple Fabric). 디스크 목록이 바뀔 때만 다시 찾는다
    private var ssdSlot: Int?
    private var pending: [TraceEvent] = []
    private var tickTimes: [UInt64] = []
    private var lastProcessed: UInt64 = 0
    private var flushOpen: [UInt64: UInt64] = [:]
    private var trimOpen: [UInt64: UInt64] = [:]
    private var execPid: [UInt64: Int32] = [:]
    private static let flushKey: UInt64 = 0x8000_0000_0000_0000
    private static let trimKey: UInt64 = 0x4000_0000_0000_0000

    private(set) var eventsRead: UInt64 = 0
    private(set) var eventsKept: UInt64 = 0         // 처리하려고 남긴 이벤트 (나머지는 읽을 때 버림)
    private(set) var ssdSkipped: UInt64 = 0         // 버린 SSD 드라이버 이벤트 (캐시 비우기·TRIM이 아닌 것, 명령마다 찍힘)
    private(set) var reorders = 0                   // 앞선 시각의 이벤트가 늦게 와서 뒤쪽을 다시 줄 세운 횟수
    private(set) var shrinks = 0                    // 몰림 뒤 대기열 용량을 줄인 횟수
    private(set) var reads = 0
    private(set) var readerCPU: UInt64 = 0
    private(set) var processCPU: UInt64 = 0
    private(set) var late = 0
    private(set) var losses = 0
    private(set) var syncs: [UInt64: Int] = [:]
    private(set) var trims = 0                  // TRIM 범위 (디스크 명령 이벤트)
    private(set) var trimBytes: UInt64 = 0
    private(set) var flushes = 0                // 끝까지 본 캐시 비우기
    private(set) var flushNs: UInt64 = 0
    private(set) var flushStarts = 0
    private(set) var trimSpans = 0              // 끝까지 본 TRIM 명령 (SSD 이벤트)
    private(set) var trimSpanNs: UInt64 = 0
    private(set) var fullSyncsInternal = 0      // 내장 SSD로 간 전체 동기화 요청 (옵션 0)
    private(set) var nonDisk: [Int32: Int] = [:]
    private(set) var unknown: [Int32: Int] = [:]
    private(set) var mapRefreshes = 0
    private var unknownSinceRefresh = 0
    private(set) var ssdEvents = false
    /// 참이면 프로그램 실행 이벤트를 모은다 (takeExecs로 꺼낸다)
    var watchExecs = false
    private var execs: [ExecEvent] = []

    /// map: 쓸 디스크 목록 (없으면 만든다). ssdEvents: 형식 필터를 이미 건 경우 그 값 (setFilter를 부르지 않을 때).
    /// capacity: 한 번에 읽는 이벤트 수 (65,536개 = 4 MiB)
    init(map given: DiskMap? = nil, ssdEvents: Bool = false, capacity: Int = 65_536) {
        let m = given ?? DiskMap()
        reader = TraceReader(capacity: capacity)
        map = m
        mapBuiltAt = Timebase.now()
        ssdDisk = m.internalSSD
        self.ssdEvents = ssdEvents
    }

    var unmatchedDone: UInt64 { meter.unmatchedDone }
    var replacedStart: UInt64 { meter.replacedStart }
    var dropped: UInt64 { meter.dropped }

    /// 전체 동기화 요청은 오는데 캐시 비우기 이벤트가 하나도 없으면, 이 macOS에서는 SSD 이벤트의 뜻이 바뀐 것으로 본다.
    /// 그래도 활성 %는 디스크 I/O만으로 맞게 나온다 (캐시 비우기 몫이 0이 될 뿐).
    var flushEventsMissing: Bool { ssdEvents && fullSyncsInternal >= 5 && flushStarts == 0 }

    /// 받는 종류: 디스크 I/O·디스크 명령은 늘, SSD 드라이버 이벤트는 ssd가 참일 때만 (DBG_TRACE는 커널이 늘 넣는다)
    static func kinds(ssd: Bool) -> [UInt32] {
        ssd ? [KD.cscDiskIO, KD.cscIoctl, KD.cscSSD] : [KD.cscDiskIO, KD.cscIoctl]
    }

    func setFilter(ssd: Bool) throws {
        try Kdebug.setTypeFilter(Engine.kinds(ssd: ssd))
        ssdEvents = ssd
    }

    /// 새 디스크 목록을 쓴다 (hold가 바뀐 것을 알아채고 넘겨준다). 장치 → 자리 기억은 지운다
    func useMap(_ newMap: DiskMap) {
        map = newMap
        mapBuiltAt = Timebase.now()
        unknownSinceRefresh = 0
        mapRefreshes += 1
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

    /// 디스크 목록 다시 만들기: 모르는 장치가 보였으면 2초 뒤, 아니면 30초마다 (꽂고 빼기). 2단계 명령이 쓴다
    func refreshMapIfNeeded() {
        let now = Timebase.now()
        if wantsNewMap(at: now) || minus(now, mapBuiltAt) > 30_000_000_000 {
            useMap(DiskMap())
        }
    }

    /// 쌓인 이벤트를 읽어 처리 대기열에 바로 붙인다 (다 비울 때까지). 소유권을 잃었으면 EBUSY로 던진다.
    /// SSD 드라이버 이벤트는 캐시 비우기·TRIM만 남긴다 (무거운 부하에서 이벤트의 약 60%가 명령마다 찍히는 SSD 이벤트)
    func read() throws {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { readerCPU += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0 }
        var execData: [(thread: UInt64, pid: Int32)] = []
        var execNames: [(time: UInt64, thread: UInt64, name: String)] = []
        let watch = watchExecs
        let start = pending.count
        var last = pending.last?.time ?? 0
        var inOrder = true
        var oldest = UInt64.max                 // 이번에 붙인 것 중 가장 이른 시각
        let processedUpTo = lastProcessed
        var lateHere = 0
        var kept: UInt64 = 0
        var skipped: UInt64 = 0
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
                        if e.time < processedUpTo { lateHere += 1 }
                        queue.append(e)
                        kept += 1
                    } else if e.csc == KD.cscSSD {
                        skipped += 1
                    } else if watch && e.debugid == KD.execData {
                        execData.append((thread: e.thread, pid: Int32(truncatingIfNeeded: e.arg1)))
                    } else if watch && e.debugid == KD.execString {
                        execNames.append((time: e.time, thread: e.thread, name: Engine.execName(e)))
                    }
                }
                eventsRead += UInt64(n)
                reads += 1
                if n < reader.capacity { break }
            }
        } catch {
            failure = error             // 읽은 만큼은 대기열에 두고 던진다
        }
        swap(&queue, &pending)
        eventsKept += kept
        ssdSkipped += skipped
        late += lateHere
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
        reorders += 1
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

    /// 표본 시각을 더한다 (그 시각의 누적값을 process가 돌려준다)
    func addTick(_ time: UInt64) {
        tickTimes.append(time)
    }

    /// cutoff까지의 이벤트와 표본 시각을 시각 순서대로 처리한다. 지난 표본 시각마다 누적값을 돌려준다.
    func process(until cutoff: UInt64) -> [(time: UInt64, totals: [UInt64: DiskTotals])] {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { processCPU += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0 }
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
        // 몰림 뒤에 큰 용량이 남지 않게 줄인다 (밤새 기록: 몰림 뒤 메모리가 18~21 MB에 머묾)
        if pending.capacity > 65_536 && pending.count < pending.capacity / 8 {
            var fresh: [TraceEvent] = []
            fresh.reserveCapacity(max(pending.count * 2, 4_096))
            fresh.append(contentsOf: pending)
            pending = fresh
            shrinks += 1
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
            out[id] = DiskTotals(busy: meter.busyNs(slot: s, meter: 0, at: t),
                                 busyWithFlush: meter.busyNs(slot: s, meter: 1, at: t),
                                 busyWithTrim: meter.busyNs(slot: s, meter: 2, at: t),
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

    /// 내장 SSD의 자리 (캐시 비우기·TRIM이 처음 시작할 때 만든다: 4단계 전 BusyMeter와 같게, 그것만 있던 디스크도 표본에 나온다)
    private func internalSSDSlot() -> Int? {
        if let s = ssdSlot { return s }
        guard let id = ssdDisk else { return nil }
        let s = meter.slot(for: id)
        ssdSlot = s
        return s
    }

    private func diskID(for dev: Int32) -> UInt64 {
        if let entry = map.devices[dev] { return entry.disk ?? 0 }
        if DiskMap.nonDiskName(dev) != nil {
            nonDisk[dev, default: 0] += 1
        } else {
            unknown[dev, default: 0] += 1
            unknownSinceRefresh += 1
        }
        return 0
    }

    private func handle(_ e: TraceEvent) {
        lastProcessed = e.time
        if e.csc == KD.cscDiskIO {
            if e.code & KD.dkioDone == 0 {
                meter.startIO(key: e.arg1, slot: slot(forDevice: Int32(truncatingIfNeeded: e.arg2)), bytes: e.arg4, at: e.time)
            } else {
                meter.doneIO(key: e.arg1, at: e.time)
            }
        } else if e.csc == KD.cscIoctl {
            if e.eventID == KD.syncRequest {
                syncs[e.arg3, default: 0] += 1
                if e.function == 0 && e.arg3 == 0, let ssd = ssdDisk,
                   map.devices[Int32(truncatingIfNeeded: e.arg1)]?.disk == ssd {
                    fullSyncsInternal += 1
                }
            } else if e.eventID == KD.trimRange {
                trims += 1
                trimBytes += e.arg3
            }
        } else if e.csc == KD.cscSSD {
            guard ssdDisk != nil else { return }
            if e.eventID == KD.ssdFlush {
                let key = Engine.flushKey | e.thread
                if e.function == KD.funcStart {
                    flushStarts += 1
                    flushOpen[e.thread] = e.time
                    if let ssd = internalSSDSlot() { meter.startCommand(key: key, slot: ssd, level: 1, at: e.time) }
                } else if e.function == KD.funcEnd {
                    if let s = flushOpen.removeValue(forKey: e.thread) {
                        flushes += 1
                        flushNs += minus(e.time, s)
                    }
                    meter.doneCommand(key: key, at: e.time)
                }
            } else if e.eventID == KD.ssdTrim {
                let key = Engine.trimKey | e.thread
                if e.function == KD.funcStart {
                    trimOpen[e.thread] = e.time
                    if let ssd = internalSSDSlot() { meter.startCommand(key: key, slot: ssd, level: 2, at: e.time) }
                } else if e.function == KD.funcEnd {
                    if let s = trimOpen.removeValue(forKey: e.thread) {
                        trimSpans += 1
                        trimSpanNs += minus(e.time, s)
                    }
                    meter.doneCommand(key: key, at: e.time)
                }
            }
        } else if e.eventID == KD.lostEvents {
            losses += 1
            meter.lose(at: e.time)
            flushOpen.removeAll()
            trimOpen.removeAll()
        }
    }
}
