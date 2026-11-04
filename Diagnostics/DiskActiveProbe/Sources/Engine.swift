// 2단계 엔진: 이벤트를 읽는 대로 시각 순서대로 처리하고, 정한 시각(1초마다)의 디스크별 누적값을 만든다.
// 나중에 보조 프로그램으로 옮길 부분이다. 1초 표본 계산과 보고는 Session(Stage2.swift)이 한다.
import Foundation

/// 한 디스크의 누적값 (어느 시각 기준)
struct DiskTotals {
    var busy: UInt64 = 0            // 바쁜 시간 (ns): 디스크 I/O 요청이 하나라도 걸려 있던 시간
    var busyWithFlush: UInt64 = 0   // 캐시 비우기까지 합친 바쁜 시간 (SSD 이벤트를 받을 때만 뜻이 있음)
    var ops: UInt64 = 0
    var bytes: UInt64 = 0
}

final class Engine {
    private(set) var map: DiskMap
    private var mapBuiltAt: UInt64
    private let reader = TraceReader(capacity: 65_536)
    private var meter = BusyMeter()
    private var withFlush = BusyMeter()
    private var pending: [TraceEvent] = []
    private var tickTimes: [UInt64] = []
    private var lastProcessed: UInt64 = 0
    private var flushOpen: [UInt64: UInt64] = [:]
    private static let flushKey: UInt64 = 0x8000_0000_0000_0000

    private(set) var eventsRead: UInt64 = 0
    private(set) var reads = 0
    private(set) var readerCPU: UInt64 = 0
    private(set) var processCPU: UInt64 = 0
    private(set) var late = 0
    private(set) var losses = 0
    private(set) var syncs: [UInt64: Int] = [:]
    private(set) var trims = 0
    private(set) var trimBytes: UInt64 = 0
    private(set) var flushes = 0
    private(set) var flushNs: UInt64 = 0
    private(set) var nonDisk: [Int32: Int] = [:]
    private(set) var unknown: [Int32: Int] = [:]
    private(set) var mapRefreshes = 0
    private var unknownSinceRefresh = 0
    private(set) var ssdEvents = false

    init() {
        map = DiskMap()
        mapBuiltAt = Timebase.now()
    }

    var unmatchedDone: UInt64 { meter.unmatchedDone }
    var replacedStart: UInt64 { meter.replacedStart }
    var dropped: UInt64 { meter.dropped }

    /// 형식 필터: 디스크 I/O·디스크 명령은 늘 받고, SSD 드라이버 이벤트는 ssd가 참일 때만
    func setFilter(ssd: Bool) throws {
        var kinds: [UInt32] = [KD.cscDiskIO, KD.cscIoctl]
        if ssd { kinds.append(KD.cscSSD) }
        try Kdebug.setTypeFilter(kinds)
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

    /// 쌓인 이벤트를 읽어 처리 대기열에 붙인다 (다 비울 때까지)
    func read() throws {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { readerCPU += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0 }
        var batch: [TraceEvent] = []
        while true {
            let n = try reader.read { e in
                if e.csc == KD.cscDiskIO || e.csc == KD.cscIoctl || e.csc == KD.cscSSD || e.eventID == KD.lostEvents {
                    batch.append(e)
                }
            }
            eventsRead += UInt64(n)
            reads += 1
            if n < reader.capacity { break }
        }
        append(batch)
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
        var out: [UInt64: DiskTotals] = [:]
        for (id, d) in meter.disks {
            out[id] = DiskTotals(busy: meter.busyNs(disk: id, at: t), busyWithFlush: withFlush.busyNs(disk: id, at: t),
                                 ops: d.completed, bytes: d.bytes)
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
            } else {
                _ = meter.done(key: e.arg1, at: e.time)
                _ = withFlush.done(key: e.arg1, at: e.time)
            }
        } else if e.csc == KD.cscIoctl {
            if e.eventID == KD.syncRequest {
                syncs[e.arg3, default: 0] += 1
            } else if e.eventID == KD.trimRange {
                trims += 1
                trimBytes += e.arg3
            }
        } else if e.csc == KD.cscSSD {
            guard e.eventID == KD.ssdFlush, let ssd = map.internalSSD else { return }
            let key = Engine.flushKey | e.thread
            if e.function == KD.funcStart {
                flushOpen[e.thread] = e.time
                withFlush.start(key: key, disk: ssd, bytes: 0, at: e.time)
            } else if e.function == KD.funcEnd {
                if let s = flushOpen.removeValue(forKey: e.thread) {
                    flushes += 1
                    flushNs += minus(e.time, s)
                }
                _ = withFlush.done(key: key, at: e.time)
            }
        } else if e.eventID == KD.lostEvents {
            losses += 1
            meter.lose(at: e.time)
            withFlush.lose(at: e.time)
            flushOpen.removeAll()
        }
    }
}
