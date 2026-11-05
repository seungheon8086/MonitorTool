// 엔진: 이벤트를 읽는 대로 시각 순서대로 처리하고, 정한 시각(1초마다)의 디스크별 누적값을 만든다.
// 나중에 보조 프로그램으로 옮길 부분이다. 1초 표본 계산과 보고는 Session(Stage2.swift)·Holder(Stage3.swift)가 한다.
// 바쁜 시간은 셋을 함께 센다 (모두 요청 구간의 합집합):
//   디스크 I/O만 ⊂ + 캐시 비우기(내장 SSD) ⊂ + TRIM(내장 SSD). 활성 %는 가운데 것 (2026-11-04 결정), TRIM은 4단계에서 정한다.
import Foundation

/// 한 디스크의 누적값 (어느 시각 기준)
struct DiskTotals {
    var busy: UInt64 = 0            // 디스크 I/O 요청이 하나라도 걸려 있던 시간 (ns)
    var busyWithFlush: UInt64 = 0   // + 캐시 비우기. SSD 이벤트를 받지 않으면 busy와 같다
    var busyWithTrim: UInt64 = 0    // + 캐시 비우기 + TRIM
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
    private var meter = BusyMeter()
    private var withFlush = BusyMeter()
    private var withTrim = BusyMeter()
    private var pending: [TraceEvent] = []
    private var tickTimes: [UInt64] = []
    private var lastProcessed: UInt64 = 0
    private var flushOpen: [UInt64: UInt64] = [:]
    private var trimOpen: [UInt64: UInt64] = [:]
    private var execPid: [UInt64: Int32] = [:]
    private static let flushKey: UInt64 = 0x8000_0000_0000_0000
    private static let trimKey: UInt64 = 0x4000_0000_0000_0000

    private(set) var eventsRead: UInt64 = 0
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

    /// ssdEvents: 형식 필터를 이미 건 경우 그 값 (setFilter를 부르지 않을 때). capacity: 한 번에 읽는 이벤트 수 (65,536개 = 4 MiB)
    init(ssdEvents: Bool = false, capacity: Int = 65_536) {
        reader = TraceReader(capacity: capacity)
        map = DiskMap()
        mapBuiltAt = Timebase.now()
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

    /// 디스크 목록 다시 만들기: 모르는 장치가 보였으면 2초 뒤, 아니면 30초마다 (꽂고 빼기)
    func refreshMapIfNeeded() {
        let now = Timebase.now()
        let age = minus(now, mapBuiltAt)
        if (unknownSinceRefresh > 0 && age > 2_000_000_000) || age > 30_000_000_000 {
            map = DiskMap()
            mapBuiltAt = now
            unknownSinceRefresh = 0
            mapRefreshes += 1
        }
    }

    /// 쌓인 이벤트를 읽어 처리 대기열에 붙인다 (다 비울 때까지). 소유권을 잃었으면 EBUSY로 던진다
    func read() throws {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { readerCPU += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0 }
        var batch: [TraceEvent] = []
        var execData: [(thread: UInt64, pid: Int32)] = []
        var execNames: [(time: UInt64, thread: UInt64, name: String)] = []
        let watch = watchExecs
        while true {
            let n = try reader.read { e in
                if e.csc == KD.cscDiskIO || e.csc == KD.cscIoctl || e.csc == KD.cscSSD || e.eventID == KD.lostEvents {
                    batch.append(e)
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
        append(batch)
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

    private func append(_ batch: [TraceEvent]) {
        guard let first = batch.first else { return }
        for e in batch where e.time < lastProcessed { late += 1 }
        if let last = pending.last, first.time < last.time {
            // 앞선 시각의 이벤트가 늦게 왔으면 합쳐서 다시 줄 세운다 (같은 시각이면 먼저 온 순서)
            let indexed = (pending + batch).enumerated().sorted { a, b in
                a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
            }
            pending = indexed.map { $0.element }
        } else {
            pending.append(contentsOf: batch)
        }
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
        while let t = tickTimes.first, t <= cutoff {
            tickTimes.removeFirst()
            out.append((time: t, totals: snapshot(at: t)))
        }
        return out
    }

    private func snapshot(at t: UInt64) -> [UInt64: DiskTotals] {
        // 30초 넘게 끝나지 않은 요청은 끝 이벤트를 잃은 것으로 본다
        meter.expire(olderThan: 30_000_000_000, at: t)
        withFlush.expire(olderThan: 30_000_000_000, at: t)
        withTrim.expire(olderThan: 30_000_000_000, at: t)
        var out: [UInt64: DiskTotals] = [:]
        // 캐시 비우기만 있고 디스크 I/O가 없던 디스크도 빠지지 않게 가장 넓은 것의 디스크 목록을 쓴다
        for id in Set(meter.disks.keys).union(withTrim.disks.keys) {
            let d = meter.disks[id]
            out[id] = DiskTotals(busy: meter.busyNs(disk: id, at: t),
                                 busyWithFlush: withFlush.busyNs(disk: id, at: t),
                                 busyWithTrim: withTrim.busyNs(disk: id, at: t),
                                 ops: d?.completed ?? 0, bytes: d?.bytes ?? 0)
        }
        return out
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
                let disk = diskID(for: Int32(truncatingIfNeeded: e.arg2))
                meter.start(key: e.arg1, disk: disk, bytes: e.arg4, at: e.time)
                withFlush.start(key: e.arg1, disk: disk, bytes: e.arg4, at: e.time)
                withTrim.start(key: e.arg1, disk: disk, bytes: e.arg4, at: e.time)
            } else {
                _ = meter.done(key: e.arg1, at: e.time)
                _ = withFlush.done(key: e.arg1, at: e.time)
                _ = withTrim.done(key: e.arg1, at: e.time)
            }
        } else if e.csc == KD.cscIoctl {
            if e.eventID == KD.syncRequest {
                syncs[e.arg3, default: 0] += 1
                if e.function == 0 && e.arg3 == 0, let ssd = map.internalSSD,
                   map.devices[Int32(truncatingIfNeeded: e.arg1)]?.disk == ssd {
                    fullSyncsInternal += 1
                }
            } else if e.eventID == KD.trimRange {
                trims += 1
                trimBytes += e.arg3
            }
        } else if e.csc == KD.cscSSD {
            guard let ssd = map.internalSSD else { return }
            if e.eventID == KD.ssdFlush {
                let key = Engine.flushKey | e.thread
                if e.function == KD.funcStart {
                    flushStarts += 1
                    flushOpen[e.thread] = e.time
                    withFlush.start(key: key, disk: ssd, bytes: 0, at: e.time)
                    withTrim.start(key: key, disk: ssd, bytes: 0, at: e.time)
                } else if e.function == KD.funcEnd {
                    if let s = flushOpen.removeValue(forKey: e.thread) {
                        flushes += 1
                        flushNs += minus(e.time, s)
                    }
                    _ = withFlush.done(key: key, at: e.time)
                    _ = withTrim.done(key: key, at: e.time)
                }
            } else if e.eventID == KD.ssdTrim {
                let key = Engine.trimKey | e.thread
                if e.function == KD.funcStart {
                    trimOpen[e.thread] = e.time
                    withTrim.start(key: key, disk: ssd, bytes: 0, at: e.time)
                } else if e.function == KD.funcEnd {
                    if let s = trimOpen.removeValue(forKey: e.thread) {
                        trimSpans += 1
                        trimSpanNs += minus(e.time, s)
                    }
                    _ = withTrim.done(key: key, at: e.time)
                }
            }
        } else if e.eventID == KD.lostEvents {
            losses += 1
            meter.lose(at: e.time)
            withFlush.lose(at: e.time)
            withTrim.lose(at: e.time)
            flushOpen.removeAll()
            trimOpen.removeAll()
        }
    }
}
