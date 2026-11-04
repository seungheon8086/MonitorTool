// 2단계: 부하 단계(load), 실시간 보기(live), 실사용 기록(record).
// 1초마다 물리 디스크별 활성 %(커널 추적)와 평균 동시 요청(드라이버 통계)을 남기고, IOReport 저장장치 채널을 나란히 읽는다.
import Foundation

// MARK: - 부하

private func stopped() -> Bool { stopRequested != 0 }

private func waitUntil(_ t: UInt64) {
    while Timebase.now() < t && !stopped() {
        let left = minus(t, Timebase.now()) / 1000
        usleep(useconds_t(min(left, 50_000)))
    }
}

/// 1 MiB씩 캐시 없이 쓴다. fileMiB 크기 파일을 돌려 쓰고, 모두 capMiB를 쓰거나 until이 되면 멈춘 뒤 F_FULLFSYNC
private func writeSequential(_ path: String, fileMiB: Int, capMiB: Int, until: UInt64) -> String {
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return "열기 실패 (errno \(errno))" }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: MiB, alignment: 16384)
    defer { buf.deallocate() }
    arc4random_buf(buf, MiB)
    var written = 0
    while written < capMiB && Timebase.now() < until && !stopped() {
        buf.storeBytes(of: UInt64(written), as: UInt64.self)
        let offset = off_t(written % fileMiB) * off_t(MiB)
        if pwrite(fd, buf, MiB, offset) != MiB { return "쓰기 실패 (errno \(errno))" }
        written += 1
    }
    _ = fcntl(fd, F_FULLFSYNC)
    return "\(written) MiB"
}

/// 1 MiB씩 캐시 없이 처음부터 끝까지 되풀이해 읽는다
private func readSequential(_ path: String, until: UInt64) -> String {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return "열기 실패 (errno \(errno))" }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_size >= off_t(MiB) else { return "파일이 너무 작음" }
    _ = fcntl(fd, F_NOCACHE, 1)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: MiB, alignment: 16384)
    defer { buf.deallocate() }
    var total = 0
    var offset: off_t = 0
    while Timebase.now() < until && !stopped() {
        let n = pread(fd, buf, MiB, offset)
        if n < 0 { return "읽기 실패 (errno \(errno))" }
        if n == 0 {
            offset = 0
            continue
        }
        total += n
        offset += off_t(n)
    }
    return "\(total / MiB) MiB"
}

private final class OpsCounter {
    private let lock = NSLock()
    private var count = 0

    func add(_ n: Int) {
        lock.lock()
        count += n
        lock.unlock()
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// 4 KiB 무작위 읽기를 스레드 threads개로 until까지 (스레드마다 한 번에 하나씩). 읽은 횟수, 실패하면 nil
private func randomOps(_ path: String, threads: Int, until: UInt64) -> Int? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    let blocks = UInt32(min(UInt64(st.st_size) / 4096, UInt64(UInt32.max)))
    guard blocks > 0 else { return nil }
    let counter = OpsCounter()
    let group = DispatchGroup()
    for _ in 0..<threads {
        group.enter()
        Thread {
            defer { group.leave() }
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = fcntl(fd, F_NOCACHE, 1)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16384)
            defer { buf.deallocate() }
            var ops = 0
            while Timebase.now() < until && !stopped() {
                let offset = off_t(arc4random_uniform(blocks)) * 4096
                if pread(fd, buf, 4096, offset) <= 0 { break }
                ops += 1
            }
            counter.add(ops)
        }.start()
    }
    group.wait()
    return counter.total
}

private func readRandom(_ path: String, threads: Int, until: UInt64) -> String {
    guard let ops = randomOps(path, threads: threads, until: until) else { return "파일 없음" }
    return "\(comma(ops))번"
}

/// 1초마다 burstMs 동안만 4 KiB 무작위 읽기를 스레드 threads개로 (count번)
private func readBursts(_ path: String, start: UInt64, count: Int, burstMs: UInt64, threads: Int) -> String {
    var total = 0
    var done = 0
    for i in 0..<count {
        let s = start + UInt64(i) * 1_000_000_000
        waitUntil(s)
        if stopped() { break }
        guard let ops = randomOps(path, threads: threads, until: s + burstMs * 1_000_000) else { return "파일 없음" }
        total += ops
        done += 1
    }
    return "\(done)번 몰림 · \(comma(total))번"
}

/// 4 KiB 쓰기 뒤 F_FULLFSYNC(full) 또는 fsync를 되풀이한다 (데이터베이스 커밋처럼)
private func syncLoop(_ path: String, full: Bool, until: UInt64) -> String {
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return "열기 실패 (errno \(errno))" }
    defer { close(fd) }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16384)
    defer { buf.deallocate() }
    arc4random_buf(buf, 4096)
    var count = 0
    while Timebase.now() < until && !stopped() {
        buf.storeBytes(of: UInt64(count), as: UInt64.self)
        if pwrite(fd, buf, 4096, off_t(count % 256) * 4096) != 4096 { return "쓰기 실패 (errno \(errno))" }
        let r = full ? fcntl(fd, F_FULLFSYNC) : fsync(fd)
        if r != 0 { return "\(full ? "F_FULLFSYNC" : "fsync") 실패 (errno \(errno))" }
        count += 1
    }
    return "\(comma(count))번"
}

struct Phase {
    let name: String
    let seconds: Int
    let ssd: Bool                                   // 이 단계 동안 SSD 드라이버 이벤트를 받는다
    let work: ((UInt64, UInt64) -> String)?         // (시작 시각, 끝 시각) → 결과 글
}

/// 부하 단계표. sdPath가 있으면 SD 카드 단계를 더한다.
func loadPhases(directory: String, sdFile: String?) -> [Phase] {
    let file = directory + "/load.bin"
    let syncFile = directory + "/sync.bin"
    var phases: [Phase] = [
        Phase(name: "가만히", seconds: 20, ssd: false, work: nil),
        Phase(name: "순차 쓰기 1MiB", seconds: 10, ssd: false, work: { _, until in
            "쓰기 " + writeSequential(file, fileMiB: 1024, capMiB: 2048, until: until) }),
        Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
        Phase(name: "순차 읽기 1MiB", seconds: 10, ssd: false, work: { _, until in
            "읽기 " + readSequential(file, until: until) }),
        Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
        Phase(name: "무작위 4KiB 동시 1", seconds: 10, ssd: false, work: { _, until in
            readRandom(file, threads: 1, until: until) }),
        Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
        Phase(name: "무작위 4KiB 동시 8", seconds: 10, ssd: false, work: { _, until in
            readRandom(file, threads: 8, until: until) }),
        Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
        Phase(name: "무작위 4KiB 동시 32", seconds: 10, ssd: false, work: { _, until in
            readRandom(file, threads: 32, until: until) }),
        Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
        Phase(name: "짧게 몰림 (1초마다 0.1초, 동시 32)", seconds: 10, ssd: false, work: { start, _ in
            readBursts(file, start: start, count: 10, burstMs: 100, threads: 32) }),
        Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
        Phase(name: "fsync 잦음 (F_FULLFSYNC)", seconds: 10, ssd: true, work: { _, until in
            syncLoop(syncFile, full: true, until: until) }),
        Phase(name: "쉼", seconds: 3, ssd: true, work: nil),
        Phase(name: "fsync 잦음 (fsync)", seconds: 10, ssd: true, work: { _, until in
            syncLoop(syncFile, full: false, until: until) }),
        Phase(name: "쉼", seconds: 5, ssd: true, work: nil),
    ]
    if let sd = sdFile {
        phases += [
            Phase(name: "SD 쓰기 1MiB", seconds: 10, ssd: false, work: { _, until in
                "쓰기 " + writeSequential(sd, fileMiB: 256, capMiB: 512, until: until) }),
            Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
            Phase(name: "SD 읽기 1MiB", seconds: 10, ssd: false, work: { _, until in
                "읽기 " + readSequential(sd, until: until) }),
            Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
            Phase(name: "SD 무작위 4KiB 동시 1", seconds: 10, ssd: false, work: { _, until in
                readRandom(sd, threads: 1, until: until) }),
            Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
            Phase(name: "SD 무작위 4KiB 동시 8", seconds: 10, ssd: false, work: { _, until in
                readRandom(sd, threads: 8, until: until) }),
            Phase(name: "쉼", seconds: 5, ssd: false, work: nil),
        ]
    }
    phases.append(Phase(name: "가만히 (끝)", seconds: 10, ssd: false, work: nil))
    return phases
}

// MARK: - 표본

/// 1초마다 찍는 기록: 그 시각의 드라이버 통계, 그 전 1초 동안의 IOReport 증가량
struct TickRecord {
    let time: UInt64
    let second: Int
    let wall: String
    let phase: Int              // 이 시각부터 시작하는 1초의 단계 번호 (-1이면 끝)
    let stats: [UInt64: DriverStats]
    let io: [IOReportValue]
    let ssdBefore: Bool         // 이 시각까지 SSD 이벤트를 받고 있었나
    let ssdAfter: Bool          // 이 시각부터 받나
}

/// 디스크 하나의 1초 표본
struct DiskSample {
    let second: Int
    let phase: Int
    let disk: UInt64
    let length: UInt64
    let busy: UInt64
    let flush: UInt64?          // 캐시 비우기로 더해지는 바쁜 시간 (SSD 이벤트를 받지 않은 1초면 nil)
    let traceOps: UInt64
    let traceBytes: UInt64
    let driver: DriverStats

    var active: Double { length == 0 ? 0 : Double(busy) / Double(length) * 100 }
    var concurrency: Double { length == 0 ? 0 : Double(driver.time) / Double(length) }
    /// 권한 없이 만들 수 있는 어림값: 1초 평균 동시 요청을 100%에서 자른 것
    var clipped: Double { min(concurrency, 1) * 100 }
}

func difference(_ b: DriverStats, _ a: DriverStats) -> DriverStats {
    DriverStats(bytesRead: minus(b.bytesRead, a.bytesRead), bytesWritten: minus(b.bytesWritten, a.bytesWritten),
                opsRead: minus(b.opsRead, a.opsRead), opsWritten: minus(b.opsWritten, a.opsWritten),
                timeRead: minus(b.timeRead, a.timeRead), timeWritten: minus(b.timeWritten, a.timeWritten))
}

func pearson(_ pairs: [(Double, Double)]) -> Double? {
    guard pairs.count >= 10 else { return nil }
    let n = Double(pairs.count)
    let mx = pairs.reduce(0.0) { $0 + $1.0 } / n
    let my = pairs.reduce(0.0) { $0 + $1.1 } / n
    var sxy = 0.0
    var sxx = 0.0
    var syy = 0.0
    for (x, y) in pairs {
        sxy += (x - mx) * (y - my)
        sxx += (x - mx) * (x - mx)
        syy += (y - my) * (y - my)
    }
    guard sxx > 0, syy > 0 else { return nil }
    return sxy / (sxx * syy).squareRoot()
}

func f1(_ v: Double) -> String { String(format: "%.1f", v) }
func f2(_ v: Double) -> String { String(format: "%.2f", v) }

/// 탭으로 나눈 줄을 모아 파일에 쓴다
final class LineWriter {
    private let handle: FileHandle?
    private var buffer = ""

    init(path: String, header: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        buffer = header + "\n"
    }

    func write(_ line: String) {
        buffer += line + "\n"
        if buffer.utf8.count > 262_144 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle?.write(buffer.data(using: .utf8)!)
        buffer = ""
    }

    func close() {
        flush()
        try? handle?.close()
    }
}

// MARK: - 세션

final class Session {
    enum Mode { case load, live, record }

    let mode: Mode
    let directory: String
    let phases: [Phase]
    let totalSeconds: Int?
    let report: Report
    let engine: Engine
    private let subscriptions: [IOReportSubscription]
    private let samplesFile: LineWriter
    private let ioreportFile: LineWriter
    private let clock = DateFormatter()
    private var ticks: [TickRecord] = []
    private var previous: (record: TickRecord, totals: [UInt64: DiskTotals])?
    private(set) var samples: [DiskSample] = []
    private var ioSeries: [String: [Int: Double]] = [:]
    private var diskNames: [UInt64: PhysicalDisk] = [:]
    private let workGroup = DispatchGroup()
    private var started: UInt64 = 0
    /// IOReport 표본을 만드는 데 쓴 CPU (ns). 붙일 때의 비용에서 뺄 몫
    private(set) var ioreportCPU: UInt64 = 0

    init(mode: Mode, directory: String, phases: [Phase], totalSeconds: Int?, report: Report, engine: Engine) {
        self.mode = mode
        self.directory = directory
        self.phases = phases
        self.totalSeconds = totalSeconds
        self.report = report
        self.engine = engine
        samplesFile = LineWriter(path: directory + "/samples.tsv",
                                 header: "second\twall\tphase\tdisk\tactive_pct\tbusy_ms\tclipped_pct\tconcurrency\ttrace_ops\ttrace_mb\tdriver_ops\tdriver_read_mb\tdriver_write_mb\tdriver_time_ms\tlatency_ms\tflush_ms")
        ioreportFile = LineWriter(path: directory + "/ioreport.tsv",
                                  header: "second\tphase\tgroup\tsubgroup\tchannel\tstate\tdelta\tcurrent")
        var made: [IOReportSubscription] = []
        if let library = IOReportLibrary() {
            let ans2: Set<String> = ["status", "power state", "Power state", "Duty cycle", "Sleep count", "Wake count",
                                     "Thread time", "Raid Read", "Raid Write", "VLane Read", "VLane Write", "AES F2H", "AES H2F"]
            let groups: [(String, Set<String>?)] = [("ANS2", ans2), ("NVMe", nil), ("SDXC Controller", nil)]
            for (group, keep) in groups {
                if let s = IOReportSubscription(library: library, group: group, keep: keep) { made.append(s) }
            }
        }
        subscriptions = made
        clock.dateFormat = "HH:mm:ss"
    }

    func phaseName(_ index: Int) -> String {
        switch mode {
        case .load: return index >= 0 && index < phases.count ? phases[index].name : "끝"
        case .live: return "보기"
        case .record: return "기록"
        }
    }

    /// k초째 시작하는 1초의 단계 번호. 다 끝났으면 -1
    private func phaseIndex(second k: Int) -> Int {
        switch mode {
        case .load:
            var edge = 0
            for (i, p) in phases.enumerated() {
                edge += p.seconds
                if k < edge { return i }
            }
            return -1
        case .live, .record:
            if let total = totalSeconds, k >= total { return -1 }
            return 0
        }
    }

    func describeIOReport() -> String {
        if subscriptions.isEmpty { return "IOReport: 구독 못 함" }
        let parts = subscriptions.map { "\($0.group) \($0.channelKeys.count)개" }
        var text = ""
        for s in subscriptions {
            text += "== \(s.group)\n" + s.channelKeys.joined(separator: "\n") + "\n"
        }
        writeText(directory + "/ioreport-channels.txt", text)
        return "IOReport: " + parts.joined(separator: " · ")
    }

    private func sampleIOReport() -> [IOReportValue] {
        var out: [IOReportValue] = []
        for s in subscriptions {
            if let values = s.sample() { out += values }
        }
        return out
    }

    private func startWork(_ index: Int, start: UInt64) {
        guard index >= 0, index < phases.count, let work = phases[index].work else { return }
        let until = start + UInt64(phases[index].seconds) * 1_000_000_000
        let name = phases[index].name
        let report = self.report
        let group = workGroup
        group.enter()
        Thread {
            let note = work(start, until)
            report.line("    └ \(name): \(note)")
            group.leave()
        }.start()
    }

    /// 표본 시각을 찍는다: 지난 1초를 닫고(통계·IOReport), 단계에 맞춰 SSD 이벤트를 켜고 끈다
    private func tick(second k: Int, phase index: Int) {
        let now = Timebase.now()
        let stats = engine.map.allStats()
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let io = sampleIOReport()
        ioreportCPU += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0
        let ssdBefore = engine.ssdEvents
        let wantSSD: Bool
        if mode == .load {
            wantSSD = index >= 0 && index < phases.count && phases[index].ssd
        } else {
            wantSSD = true
        }
        if wantSSD != engine.ssdEvents {
            do { try engine.setFilter(ssd: wantSSD) } catch { report.line("  SSD 이벤트 \(wantSSD ? "켜기" : "끄기") 실패: \(error)") }
        }
        for d in engine.map.physical { diskNames[d.id] = d }
        let record = TickRecord(time: now, second: k, wall: clock.string(from: Date()), phase: index, stats: stats, io: io,
                                ssdBefore: ssdBefore, ssdAfter: engine.ssdEvents)
        ticks.append(record)
        engine.addTick(now)
    }

    /// 단계표대로 돌린다. 끝나거나 Ctrl-C면 돌아온다
    func perform() {
        started = Timebase.now()
        var k = 0
        var nextTick = started
        var current = -2
        while true {
            if Timebase.now() >= nextTick {
                let index = phaseIndex(second: k)
                tick(second: k, phase: index)
                if index != current {
                    current = index
                    if index >= 0 {
                        if mode == .load { report.line("  [\(k)초] \(phases[index].name)") }
                        startWork(index, start: nextTick)
                    }
                }
                if index < 0 { break }
                k += 1
                nextTick = started + UInt64(k) * 1_000_000_000
            }
            do {
                try engine.read()
            } catch {
                report.line("  읽기 중단: \(error)")
                break
            }
            consume(engine.process(until: minus(Timebase.now(), 20_000_000)))
            engine.refreshMapIfNeeded()
            if stopped() {
                // 남은 몇 분의 1초도 표본으로 남긴다
                tick(second: k, phase: -1)
                break
            }
            let left = minus(min(nextTick, Timebase.now() + 100_000_000), Timebase.now()) / 1000
            if left > 0 { usleep(useconds_t(min(left, 100_000))) }
        }
        _ = workGroup.wait(timeout: .now() + 30)
    }

    /// 기록을 끈 뒤 남은 이벤트를 모두 처리한다
    func finish() {
        for _ in 0..<5 { try? engine.read() }
        consume(engine.process(until: UInt64.max))
        samplesFile.close()
        ioreportFile.close()
    }

    private func consume(_ produced: [(time: UInt64, totals: [UInt64: DiskTotals])]) {
        for item in produced {
            guard !ticks.isEmpty else { break }
            let record = ticks.removeFirst()
            if let prev = previous {
                emit(from: prev.record, prevTotals: prev.totals, to: record, totals: item.totals)
            }
            previous = (record: record, totals: item.totals)
            if record.second % 10 == 0 {
                samplesFile.flush()
                ioreportFile.flush()
            }
        }
    }

    private func emit(from a: TickRecord, prevTotals: [UInt64: DiskTotals], to b: TickRecord, totals: [UInt64: DiskTotals]) {
        let length = minus(b.time, a.time)
        let flushValid = a.ssdAfter && b.ssdBefore
        var live: [String] = []
        for (id, disk) in diskNames.sorted(by: { $0.value.bsd.localizedStandardCompare($1.value.bsd) == .orderedAscending }) {
            guard let s0 = a.stats[id], let s1 = b.stats[id] else { continue }
            let t0 = prevTotals[id] ?? DiskTotals()
            let t1 = totals[id] ?? DiskTotals()
            let busy = minus(t1.busy, t0.busy)
            let flush: UInt64? = flushValid ? minus(minus(t1.busyWithFlush, t0.busyWithFlush), busy) : nil
            let sample = DiskSample(second: a.second, phase: a.phase, disk: id, length: length, busy: busy, flush: flush,
                                    traceOps: minus(t1.ops, t0.ops), traceBytes: minus(t1.bytes, t0.bytes),
                                    driver: difference(s1, s0))
            samples.append(sample)
            let latency = sample.driver.ops == 0 ? "" : String(format: "%.3f", Double(sample.driver.time) / Double(sample.driver.ops) / 1e6)
            samplesFile.write("\(a.second)\t\(a.wall)\t\(phaseName(a.phase))\t\(disk.bsd)\t\(f2(sample.active))\t\(ms(busy))"
                + "\t\(f2(sample.clipped))\t\(String(format: "%.4f", sample.concurrency))\t\(sample.traceOps)\t\(mb(sample.traceBytes))"
                + "\t\(sample.driver.ops)\t\(mb(sample.driver.bytesRead))\t\(mb(sample.driver.bytesWritten))\t\(ms(sample.driver.time))"
                + "\t\(latency)\t\(flush.map { ms($0) } ?? "")")
            if mode != .load {
                var text = "\(disk.bsd) 활성 \(String(format: "%5.1f", sample.active))% · 동시 \(f2(sample.concurrency))"
                    + " · 읽기 \(String(format: "%6.1f", Double(sample.driver.bytesRead) / 1e6)) · 쓰기 \(String(format: "%6.1f", Double(sample.driver.bytesWritten) / 1e6)) MB/s"
                if !latency.isEmpty { text += " · 응답 \(latency) ms" }
                if let f = flush, f > 0 { text += " · 캐시 비우기 \(ms(f)) ms" }
                live.append(text)
            }
        }
        if mode != .load && !live.isEmpty {
            print(a.wall + "  " + live.joined(separator: "  │  "))
        }
        // b.io = (a, b] 동안의 IOReport 증가량
        var channelTotal: [String: Int64] = [:]
        for v in b.io where !v.state.isEmpty { channelTotal[v.key, default: 0] += max(v.delta, 0) }
        for v in b.io {
            ioreportFile.write("\(a.second)\t\(phaseName(a.phase))\t\(v.key.replacingOccurrences(of: " / ", with: "\t"))\t\(v.state)\t\(v.delta)\t\(v.current)")
            if v.state.isEmpty {
                ioSeries[v.key, default: [:]][a.second] = Double(v.delta)
            } else if let total = channelTotal[v.key], total > 0 {
                ioSeries[v.key + " · " + v.state, default: [:]][a.second] = Double(max(v.delta, 0)) / Double(total) * 100
            }
        }
    }

    // MARK: 보고

    private func activeSeries(_ disk: UInt64) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for s in samples where s.disk == disk { out[s.second] = s.active }
        return out
    }

    /// 활성 %와 상관이 큰 IOReport 계열 (|r| 큰 순)
    func correlations(_ disk: UInt64) -> [(name: String, r: Double, n: Int)] {
        let active = activeSeries(disk)
        var out: [(name: String, r: Double, n: Int)] = []
        for (name, series) in ioSeries {
            var pairs: [(Double, Double)] = []
            for (second, value) in series {
                if let a = active[second] { pairs.append((a, value)) }
            }
            if let r = pearson(pairs) { out.append((name: name, r: r, n: pairs.count)) }
        }
        return out.sorted { abs($0.r) > abs($1.r) }
    }

    func summarize() {
        let disks = diskNames.values.sorted { $0.bsd.localizedStandardCompare($1.bsd) == .orderedAscending }
        var phaseLines = "index\tphase\tseconds\tdisk\tactive_pct\tclipped_mean_pct\tconcurrency\tread_mbs\twrite_mbs\tlatency_ms\ttrace_ops\tdriver_ops\ttrace_mb\tdriver_mb\tbusy_ms\tflush_ms\n"
        for disk in disks {
            let mine = samples.filter { $0.disk == disk.id }
            if mine.isEmpty { continue }
            let groups: [(index: Int, rows: [DiskSample])]
            if mode == .load {
                groups = (0..<phases.count).map { i in (index: i, rows: mine.filter { $0.phase == i }) }.filter { !$0.rows.isEmpty }
            } else {
                groups = [(index: 0, rows: mine)]
            }
            let anyActivity = mine.contains { $0.driver.ops > 0 || $0.busy > 0 }
            if !anyActivity { continue }
            report.line("")
            report.line("== 단계별 · \(disk.bsd) \(disk.name)")
            report.line("  단계 | 길이 | 활성 | 1초 동시 자른 평균 | 평균 동시 | 읽기·쓰기 MB/s | 응답 ms | 작업 추적·드라이버 | 캐시 비우기 ms")
            var traceOps: UInt64 = 0
            var driverOps: UInt64 = 0
            var traceBytes: UInt64 = 0
            var driverBytes: UInt64 = 0
            for g in groups {
                let length = g.rows.reduce(UInt64(0)) { $0 + $1.length }
                let busy = g.rows.reduce(UInt64(0)) { $0 + $1.busy }
                let dTime = g.rows.reduce(UInt64(0)) { $0 + $1.driver.time }
                let dOps = g.rows.reduce(UInt64(0)) { $0 + $1.driver.ops }
                let tOps = g.rows.reduce(UInt64(0)) { $0 + $1.traceOps }
                let tBytes = g.rows.reduce(UInt64(0)) { $0 + $1.traceBytes }
                let rBytes = g.rows.reduce(UInt64(0)) { $0 + $1.driver.bytesRead }
                let wBytes = g.rows.reduce(UInt64(0)) { $0 + $1.driver.bytesWritten }
                let flushRows = g.rows.compactMap { $0.flush }
                let flush = flushRows.reduce(UInt64(0), +)
                let clippedMean = g.rows.reduce(0.0) { $0 + $1.clipped } / Double(g.rows.count)
                let secondsLength = Double(length) / 1e9
                let active = length == 0 ? 0 : Double(busy) / Double(length) * 100
                let concurrency = length == 0 ? 0 : Double(dTime) / Double(length)
                let latency = dOps == 0 ? "—" : String(format: "%.3f", Double(dTime) / Double(dOps) / 1e6)
                let readRate = secondsLength == 0 ? 0 : Double(rBytes) / 1e6 / secondsLength
                let writeRate = secondsLength == 0 ? 0 : Double(wBytes) / 1e6 / secondsLength
                traceOps += tOps
                driverOps += dOps
                traceBytes += tBytes
                driverBytes += rBytes + wBytes
                let flushText = flushRows.isEmpty ? "—" : ms(flush)
                report.line("  \(phaseName(g.index)) | \(String(format: "%.0f", secondsLength))초 | \(f1(active))% | \(f1(clippedMean))% | \(f2(concurrency))"
                    + " | \(f1(readRate))·\(f1(writeRate)) | \(latency) | \(comma(tOps))·\(comma(dOps)) | \(flushText)")
                phaseLines += "\(g.index)\t\(phaseName(g.index))\t\(String(format: "%.3f", secondsLength))\t\(disk.bsd)\t\(f2(active))\t\(f2(clippedMean))"
                    + "\t\(String(format: "%.4f", concurrency))\t\(f2(readRate))\t\(f2(writeRate))\t\(latency)\t\(tOps)\t\(dOps)"
                    + "\t\(mb(tBytes))\t\(mb(rBytes + wBytes))\t\(ms(busy))\t\(flushRows.isEmpty ? "" : ms(flush))\n"
            }
            report.line("  모두: 작업 추적 \(comma(traceOps)) · 드라이버 \(comma(driverOps)) (\(percent(traceOps, driverOps))) · 바이트 추적 \(mb(traceBytes)) MB · 드라이버 \(mb(driverBytes)) MB (\(percent(traceBytes, driverBytes)))")
            if mode != .load {
                histogram(mine, disk: disk)
            }
        }
        writeText(directory + "/phases.tsv", phaseLines)

        // 캐시 비우기 (SSD 이벤트를 받은 1초들)
        if let ssd = engine.map.internalSSD {
            let rows = samples.filter { $0.disk == ssd && $0.flush != nil }
            if !rows.isEmpty {
                let flush = rows.reduce(UInt64(0)) { $0 + ($1.flush ?? 0) }
                let busy = rows.reduce(UInt64(0)) { $0 + $1.busy }
                report.line("")
                report.line("== 캐시 비우기 (SSD 드라이버 이벤트를 받은 \(rows.count)초, 내장 SSD)")
                report.line("  캐시 비우기 \(comma(engine.flushes))번 · 합 \(ms(engine.flushNs)) ms · 디스크 I/O 밖으로 더해지는 바쁜 시간 \(ms(flush)) ms")
                report.line("  같은 1초들의 디스크 I/O 바쁜 시간 \(ms(busy)) ms → 캐시 비우기를 넣으면 \(percent(flush, busy)) 늘어남")
            }
        }

        // 디스크 명령과 장치
        report.line("")
        report.line("== 디스크 명령·장치")
        let syncText = engine.syncs.keys.sorted().map { "옵션 \($0) \(comma(engine.syncs[$0]!))" }.joined(separator: " · ")
        report.line("  동기화 요청 \(comma(engine.syncs.values.reduce(0, +)))개" + (syncText.isEmpty ? "" : " (\(syncText))")
            + " · TRIM 범위 \(comma(engine.trims))개 \(mb(engine.trimBytes)) MB")
        let nonDiskText = engine.nonDisk.map { "\(DiskMap.nonDiskName($0.key) ?? "?") \(comma($0.value))" }.joined(separator: " · ")
        report.line("  디스크가 아닌 장치: " + (nonDiskText.isEmpty ? "없음" : nonDiskText))
        let unknownText = engine.unknown.map { "\(devText($0.key)) \(comma($0.value))" }.joined(separator: " · ")
        report.line("  모르는 장치: " + (unknownText.isEmpty ? "없음" : unknownText) + " · 디스크 목록 다시 만듦 \(engine.mapRefreshes)번")

        // IOReport
        for disk in disks {
            let mine = samples.filter { $0.disk == disk.id }
            guard mine.contains(where: { $0.busy > 0 }) else { continue }
            let top = correlations(disk.id).prefix(8)
            report.line("")
            report.line("== IOReport와 활성 %의 상관 · \(disk.bsd) (1초 표본, |r| 큰 순)")
            if top.isEmpty { report.line("  계산할 계열 없음") }
            for c in top { report.line("  r = \(String(format: "%+.3f", c.r)) · \(c.name) (n=\(c.n))") }
            if mode == .load && !top.isEmpty {
                let chosen = Array(top.prefix(3))
                report.line("  단계별 평균: 단계 | 활성 | " + chosen.map { $0.name }.joined(separator: " | "))
                for i in 0..<phases.count {
                    let rows = mine.filter { $0.phase == i }
                    if rows.isEmpty { continue }
                    let seconds = Set(rows.map { $0.second })
                    let active = rows.reduce(0.0) { $0 + $1.active } / Double(rows.count)
                    var cells: [String] = []
                    for c in chosen {
                        let values = (ioSeries[c.name] ?? [:]).filter { seconds.contains($0.key) }.map { $0.value }
                        cells.append(values.isEmpty ? "—" : String(format: "%.1f", values.reduce(0, +) / Double(values.count)))
                    }
                    report.line("    \(phaseName(i)) | \(f1(active))% | " + cells.joined(separator: " | "))
                }
            }
        }
    }

    /// 실사용 기록: 1초 활성 %의 분포와 어림값(자른 동시)과의 차이
    private func histogram(_ rows: [DiskSample], disk: PhysicalDisk) {
        let edges: [(String, Double, Double)] = [("0%", 0, 0.05), ("~1%", 0.05, 1), ("1~5%", 1, 5), ("5~20%", 5, 20),
                                                  ("20~50%", 20, 50), ("50~90%", 50, 90), ("90%~", 90, 1000)]
        let counts = edges.map { e in rows.filter { $0.active >= e.1 && $0.active < e.2 }.count }
        let text = zip(edges, counts).map { "\($0.0) \($1)" }.joined(separator: " · ")
        report.line("  1초 활성 분포 (\(rows.count)초): \(text)")
        let sorted = rows.map { $0.active }.sorted()
        if !sorted.isEmpty {
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            report.line("  활성 평균 \(f1(mean))% · 중앙 \(f1(sorted[sorted.count / 2]))% · 90% \(f1(sorted[sorted.count * 9 / 10]))% · 최대 \(f1(sorted[sorted.count - 1]))%")
        }
        let withFlush = rows.compactMap { r -> Double? in
            guard let f = r.flush, r.length > 0 else { return nil }
            return Double(r.busy + f) / Double(r.length) * 100
        }.sorted()
        if !withFlush.isEmpty {
            let mean = withFlush.reduce(0, +) / Double(withFlush.count)
            let changed = rows.filter { ($0.flush ?? 0) > 0 }.count
            report.line("  캐시 비우기를 넣은 활성: 평균 \(f1(mean))% · 90% \(f1(withFlush[withFlush.count * 9 / 10]))% · 최대 \(f1(withFlush[withFlush.count - 1]))% · 캐시 비우기가 있던 1초 \(changed)번")
        }
        let gaps = rows.map { $0.clipped - $0.active }
        let over5 = gaps.filter { abs($0) > 5 }.count
        let over20 = gaps.filter { abs($0) > 20 }.count
        let maxGap = gaps.map { abs($0) }.max() ?? 0
        report.line("  자른 동시 − 활성: 5%p 넘게 다른 1초 \(over5)번 · 20%p 넘게 \(over20)번 · 가장 큰 차이 \(f1(maxGap))%p")
    }
}

// MARK: - 명령

/// load·live·record 공통: 추적을 켜고, 세션을 돌리고, 해제하고, 보고서를 쓴다
func runSession(mode: Session.Mode, directory: String, minutes: Int?, sdPath: String?) -> Int32 {
    let report = Report(path: directory + "/report.txt")
    defer { report.close() }
    guard getuid() == 0 else {
        report.line("관리자 권한 필요")
        return 1
    }
    let title: String
    switch mode {
    case .load: title = "load (부하 단계)"
    case .live: title = "live (실시간 보기)"
    case .record: title = "record (실사용 기록 \(minutes ?? 0)분)"
    }
    report.line("== DiskActiveProbe 2단계 \(title) · \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))")
    report.line("\(ProcessInfo.processInfo.operatingSystemVersionString) · \(sysctlString("hw.model"))")
    report.line("추적 상태 (시작 전): \(traceState())")
    report.line("tailspin: \(firstLine(run("/usr/bin/tailspin", ["info"])))")
    let powerBefore = powermetricsState()
    report.line("powermetrics (시작 전): \(powerBefore)")

    var sdFile: String?
    if let sd = sdPath {
        var fs = statfs()
        guard statfs(sd, &fs) == 0, FileManager.default.isWritableFile(atPath: sd) else {
            report.line("SD 카드 경로에 쓸 수 없음: \(sd)")
            return 1
        }
        let free = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        guard free >= 1 << 30 else {
            report.line("SD 카드 여유 공간이 1 GB보다 작음: \(mb(free)) MB")
            return 1
        }
        sdFile = sd + "/.diskactiveprobe-\(getpid()).bin"
        report.line("SD 카드: \(sd) · 여유 \(mb(free)) MB")
    }

    let engine = Engine()
    report.line("물리 디스크")
    for d in engine.map.physical {
        report.line("  \(d.bsd) · \(d.name) · \(d.interconnect) · \(d.location)")
    }
    let phases = mode == .load ? loadPhases(directory: directory, sdFile: sdFile) : []
    let total: Int?
    switch mode {
    case .load: total = phases.reduce(0) { $0 + $1.seconds }
    case .live: total = nil
    case .record: total = (minutes ?? 10) * 60
    }
    let session = Session(mode: mode, directory: directory, phases: phases, totalSeconds: total, report: report, engine: engine)
    report.line(session.describeIOReport())

    var owning = false
    do {
        try Kdebug.setBuffer(events: 262_144)
        owning = true
        try Kdebug.clearFlags(KD.flagNoWrap | KD.flagContinuous | KD.flagMatchDisable)
        try Kdebug.setup()
        try engine.setFilter(ssd: false)
        try Kdebug.enable(true)
    } catch {
        report.line("▶ 추적 켜기: \(error)")
        if owning { try? Kdebug.remove() }
        report.line("추적 상태: \(traceState())")
        return 2
    }
    installSignalHandlers()
    installCrashRelease()
    if let i = try? Kdebug.info() {
        Timebase.continuous = i.flags & KD.flagContinuous != 0
        report.line("▶ 추적 켜기: 성공 · 커널 버퍼 \(comma(Int(i.events)))개 (\(String(format: "%.1f", Double(i.events) * 64 / 1_048_576)) MiB)"
            + (Timebase.continuous ? " · 연속 시각" : " · 절대 시각"))
    }
    switch mode {
    case .load: report.line("▶ 단계 (약 \(total ?? 0)초)")
    case .live: report.line("▶ 1초마다 (Ctrl-C로 끝)")
    case .record: report.line("▶ 기록 \(minutes ?? 10)분 (평소처럼 쓰면 됨, Ctrl-C로 일찍 끝낼 수 있음)")
    }

    let usage0 = cpuSeconds()
    let wall0 = Timebase.now()
    session.perform()
    try? Kdebug.enable(false)
    session.finish()
    var releaseText = "성공"
    do { try Kdebug.remove() } catch { releaseText = "\(error)" }
    let wall = Double(minus(Timebase.now(), wall0)) / 1e9
    let usage = cpuSeconds() - usage0
    sleep(2)
    report.line("▶ 추적 해제: \(releaseText) · 2초 뒤 \(traceState())")
    if stopRequested != 0 { report.line("  Ctrl-C로 끝냄") }
    if let f = sdFile { unlink(f) }
    unlink(directory + "/load.bin")
    unlink(directory + "/sync.bin")

    session.summarize()

    report.line("")
    report.line("== 요약")
    report.line("이벤트 \(comma(engine.eventsRead))개 · 읽기 \(comma(engine.reads))번 · 잃음 \(engine.losses)번 · 늦게 온 이벤트 \(engine.late)")
    report.line("짝 못 맞춤: 시작 못 본 끝 \(comma(engine.unmatchedDone)) · 같은 열쇠 다시 시작 \(comma(engine.replacedStart)) · 버린 요청 \(comma(engine.dropped))")
    report.line("읽기 CPU \(ms(engine.readerCPU)) ms · 처리 CPU \(ms(engine.processCPU)) ms · 도구 전체 CPU \(String(format: "%.2f", usage))초 / \(String(format: "%.0f", wall))초"
        + (mode == .load ? " (부하 스레드 포함)" : " (\(String(format: "%.2f", wall == 0 ? 0 : usage / wall * 100))%)"))
    report.line("IOReport 표본 CPU \(ms(session.ioreportCPU)) ms (비교용이라 붙일 때는 뺄 몫)")
    report.line("powermetrics: \(powerBefore) → \(powermetricsState())")
    return 0
}

/// 이 프로세스가 쓴 CPU 시간 (초, 사용자 + 시스템)
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + system
}
