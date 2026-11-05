// load(부하 단계)·live(실시간 보기)·record(실사용 기록). 2단계에서 만들고 3단계에서 고쳤다.
// 1초마다 물리 디스크별 활성 %(커널 추적)와 평균 동시 요청(드라이버 통계)을 남긴다.
// 활성 %에는 내장 SSD의 캐시 비우기를 넣고(2026-11-04 결정), TRIM은 따로 잰다. IOReport 비교는 2단계로 끝내고 뺐다.
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
func writeSequential(_ path: String, fileMiB: Int, capMiB: Int, until: UInt64) -> String {
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

func readRandom(_ path: String, threads: Int, until: UInt64) -> String {
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
    let work: ((UInt64, UInt64) -> String)?         // (시작 시각, 끝 시각) → 결과 글
}

/// 부하 단계표. sdFile이 있으면 SD 카드 단계를 더한다.
func loadPhases(directory: String, sdFile: String?) -> [Phase] {
    let file = directory + "/load.bin"
    let syncFile = directory + "/sync.bin"
    var phases: [Phase] = [
        Phase(name: "가만히", seconds: 20, work: nil),
        Phase(name: "순차 쓰기 1MiB", seconds: 10, work: { _, until in
            "쓰기 " + writeSequential(file, fileMiB: 1024, capMiB: 2048, until: until) }),
        Phase(name: "쉼", seconds: 5, work: nil),
        Phase(name: "순차 읽기 1MiB", seconds: 10, work: { _, until in
            "읽기 " + readSequential(file, until: until) }),
        Phase(name: "쉼", seconds: 5, work: nil),
        Phase(name: "무작위 4KiB 동시 1", seconds: 10, work: { _, until in
            readRandom(file, threads: 1, until: until) }),
        Phase(name: "쉼", seconds: 5, work: nil),
        Phase(name: "무작위 4KiB 동시 8", seconds: 10, work: { _, until in
            readRandom(file, threads: 8, until: until) }),
        Phase(name: "쉼", seconds: 5, work: nil),
        Phase(name: "무작위 4KiB 동시 32", seconds: 10, work: { _, until in
            readRandom(file, threads: 32, until: until) }),
        Phase(name: "쉼", seconds: 5, work: nil),
        Phase(name: "짧게 몰림 (1초마다 0.1초, 동시 32)", seconds: 10, work: { start, _ in
            readBursts(file, start: start, count: 10, burstMs: 100, threads: 32) }),
        Phase(name: "쉼", seconds: 5, work: nil),
        Phase(name: "fsync 잦음 (F_FULLFSYNC)", seconds: 10, work: { _, until in
            syncLoop(syncFile, full: true, until: until) }),
        Phase(name: "쉼", seconds: 3, work: nil),
        Phase(name: "fsync 잦음 (fsync)", seconds: 10, work: { _, until in
            syncLoop(syncFile, full: false, until: until) }),
        Phase(name: "쉼", seconds: 5, work: nil),
    ]
    if let sd = sdFile {
        phases += [
            Phase(name: "SD 쓰기 1MiB", seconds: 10, work: { _, until in
                "쓰기 " + writeSequential(sd, fileMiB: 256, capMiB: 512, until: until) }),
            Phase(name: "쉼", seconds: 5, work: nil),
            Phase(name: "SD 읽기 1MiB", seconds: 10, work: { _, until in
                "읽기 " + readSequential(sd, until: until) }),
            Phase(name: "쉼", seconds: 5, work: nil),
            Phase(name: "SD 무작위 4KiB 동시 1", seconds: 10, work: { _, until in
                readRandom(sd, threads: 1, until: until) }),
            Phase(name: "쉼", seconds: 5, work: nil),
            Phase(name: "SD 무작위 4KiB 동시 8", seconds: 10, work: { _, until in
                readRandom(sd, threads: 8, until: until) }),
            Phase(name: "쉼", seconds: 5, work: nil),
        ]
    }
    phases.append(Phase(name: "가만히 (끝)", seconds: 10, work: nil))
    return phases
}

// MARK: - 표본

/// 1초마다 찍는 기록: 그 시각의 드라이버 통계
struct TickRecord {
    let time: UInt64
    let second: Int
    let wall: String
    let phase: Int              // 이 시각부터 시작하는 1초의 단계 번호 (-1이면 끝)
    let stats: [UInt64: DriverStats]
}

/// 디스크 하나의 1초 표본
struct DiskSample {
    let second: Int
    let phase: Int
    let disk: UInt64
    let length: UInt64
    let busyIO: UInt64          // 디스크 I/O만의 바쁜 시간
    let flush: UInt64           // 캐시 비우기로 더해진 바쁜 시간 (내장 SSD 밖은 0)
    let trim: UInt64            // TRIM까지 넣으면 더 더해질 바쁜 시간 (활성에는 넣지 않음)
    let traceOps: UInt64
    let traceBytes: UInt64
    let driver: DriverStats

    /// 활성 %의 바쁜 시간: 디스크 I/O + 캐시 비우기
    var busy: UInt64 { busyIO + flush }
    var active: Double { share(busy) }
    var activeIO: Double { share(busyIO) }
    var activeWithTrim: Double { share(busy + trim) }
    var concurrency: Double { length == 0 ? 0 : Double(driver.time) / Double(length) }
    /// 권한 없이 만들 수 있는 어림값: 1초 평균 동시 요청을 100%에서 자른 것 (추적을 못 쓸 때 '추정'으로 보일 값)
    var clipped: Double { min(concurrency, 1) * 100 }

    private func share(_ ns: UInt64) -> Double { length == 0 ? 0 : Double(ns) / Double(length) * 100 }
}

func difference(_ b: DriverStats, _ a: DriverStats) -> DriverStats {
    DriverStats(bytesRead: minus(b.bytesRead, a.bytesRead), bytesWritten: minus(b.bytesWritten, a.bytesWritten),
                opsRead: minus(b.opsRead, a.opsRead), opsWritten: minus(b.opsWritten, a.opsWritten),
                timeRead: minus(b.timeRead, a.timeRead), timeWritten: minus(b.timeWritten, a.timeWritten))
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
    private let samplesFile: LineWriter
    private let clock = DateFormatter()
    private var ticks: [TickRecord] = []
    private var previous: (record: TickRecord, totals: [UInt64: DiskTotals])?
    private(set) var samples: [DiskSample] = []
    private var diskNames: [UInt64: PhysicalDisk] = [:]
    private let workGroup = DispatchGroup()
    private var started: UInt64 = 0

    init(mode: Mode, directory: String, phases: [Phase], totalSeconds: Int?, report: Report, engine: Engine) {
        self.mode = mode
        self.directory = directory
        self.phases = phases
        self.totalSeconds = totalSeconds
        self.report = report
        self.engine = engine
        samplesFile = LineWriter(path: directory + "/samples.tsv",
                                 header: "second\twall\tphase\tdisk\tactive_pct\tio_pct\tbusy_ms\tflush_ms\ttrim_ms\tclipped_pct\tconcurrency"
                                     + "\ttrace_ops\ttrace_mb\tdriver_ops\tdriver_read_mb\tdriver_write_mb\tdriver_time_ms\tlatency_ms")
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

    /// 표본 시각을 찍는다: 지난 1초를 닫는다(드라이버 통계)
    private func tick(second k: Int, phase index: Int) {
        let now = Timebase.now()
        let stats = engine.map.allStats()
        for d in engine.map.physical { diskNames[d.id] = d }
        ticks.append(TickRecord(time: now, second: k, wall: clock.string(from: Date()), phase: index, stats: stats))
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
            if stopRequested != 0 {
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
    }

    private func consume(_ produced: [(time: UInt64, totals: [UInt64: DiskTotals])]) {
        for item in produced {
            guard !ticks.isEmpty else { break }
            let record = ticks.removeFirst()
            if let prev = previous {
                emit(from: prev.record, prevTotals: prev.totals, to: record, totals: item.totals)
            }
            previous = (record: record, totals: item.totals)
            if record.second % 10 == 0 { samplesFile.flush() }
        }
    }

    private func emit(from a: TickRecord, prevTotals: [UInt64: DiskTotals], to b: TickRecord, totals: [UInt64: DiskTotals]) {
        let length = minus(b.time, a.time)
        var live: [String] = []
        for (id, disk) in diskNames.sorted(by: { $0.value.bsd.localizedStandardCompare($1.value.bsd) == .orderedAscending }) {
            guard let s0 = a.stats[id], let s1 = b.stats[id] else { continue }
            let t0 = prevTotals[id] ?? DiskTotals()
            let t1 = totals[id] ?? DiskTotals()
            let io = minus(t1.busy, t0.busy)
            let withFlush = minus(t1.busyWithFlush, t0.busyWithFlush)
            let withTrim = minus(t1.busyWithTrim, t0.busyWithTrim)
            let sample = DiskSample(second: a.second, phase: a.phase, disk: id, length: length, busyIO: io,
                                    flush: minus(withFlush, io), trim: minus(withTrim, withFlush),
                                    traceOps: minus(t1.ops, t0.ops), traceBytes: minus(t1.bytes, t0.bytes),
                                    driver: difference(s1, s0))
            samples.append(sample)
            let latency = sample.driver.ops == 0 ? "" : String(format: "%.3f", Double(sample.driver.time) / Double(sample.driver.ops) / 1e6)
            samplesFile.write("\(a.second)\t\(a.wall)\t\(phaseName(a.phase))\t\(disk.bsd)\t\(f2(sample.active))\t\(f2(sample.activeIO))"
                + "\t\(ms(sample.busy))\t\(ms(sample.flush))\t\(ms(sample.trim))"
                + "\t\(f2(sample.clipped))\t\(String(format: "%.4f", sample.concurrency))\t\(sample.traceOps)\t\(mb(sample.traceBytes))"
                + "\t\(sample.driver.ops)\t\(mb(sample.driver.bytesRead))\t\(mb(sample.driver.bytesWritten))\t\(ms(sample.driver.time))"
                + "\t\(latency)")
            if mode != .load {
                var text = "\(disk.bsd) 활성 \(String(format: "%5.1f", sample.active))% · 동시 \(f2(sample.concurrency))"
                    + " · 읽기 \(String(format: "%6.1f", Double(sample.driver.bytesRead) / 1e6)) · 쓰기 \(String(format: "%6.1f", Double(sample.driver.bytesWritten) / 1e6)) MB/s"
                if !latency.isEmpty { text += " · 응답 \(latency) ms" }
                if sample.flush > 0 { text += " · 캐시 비우기 \(ms(sample.flush)) ms" }
                if sample.trim > 0 { text += " · TRIM \(ms(sample.trim)) ms" }
                live.append(text)
            }
        }
        if mode != .load && !live.isEmpty {
            print(a.wall + "  " + live.joined(separator: "  │  "))
        }
    }

    // MARK: 보고

    func summarize() {
        let disks = diskNames.values.sorted { $0.bsd.localizedStandardCompare($1.bsd) == .orderedAscending }
        var phaseLines = "index\tphase\tseconds\tdisk\tactive_pct\tio_pct\tclipped_mean_pct\tconcurrency\tread_mbs\twrite_mbs\tlatency_ms"
            + "\ttrace_ops\tdriver_ops\ttrace_mb\tdriver_mb\tbusy_ms\tflush_ms\ttrim_ms\n"
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
            report.line("  단계 | 길이 | 활성 | 디스크 I/O만 | 1초 동시 자른 평균 | 평균 동시 | 읽기·쓰기 MB/s | 응답 ms | 작업 추적·드라이버 | 캐시 비우기 ms | TRIM ms")
            var traceOps: UInt64 = 0
            var driverOps: UInt64 = 0
            var traceBytes: UInt64 = 0
            var driverBytes: UInt64 = 0
            for g in groups {
                let length = g.rows.reduce(UInt64(0)) { $0 + $1.length }
                let busy = g.rows.reduce(UInt64(0)) { $0 + $1.busy }
                let busyIO = g.rows.reduce(UInt64(0)) { $0 + $1.busyIO }
                let flush = g.rows.reduce(UInt64(0)) { $0 + $1.flush }
                let trim = g.rows.reduce(UInt64(0)) { $0 + $1.trim }
                let dTime = g.rows.reduce(UInt64(0)) { $0 + $1.driver.time }
                let dOps = g.rows.reduce(UInt64(0)) { $0 + $1.driver.ops }
                let tOps = g.rows.reduce(UInt64(0)) { $0 + $1.traceOps }
                let tBytes = g.rows.reduce(UInt64(0)) { $0 + $1.traceBytes }
                let rBytes = g.rows.reduce(UInt64(0)) { $0 + $1.driver.bytesRead }
                let wBytes = g.rows.reduce(UInt64(0)) { $0 + $1.driver.bytesWritten }
                let clippedMean = g.rows.reduce(0.0) { $0 + $1.clipped } / Double(g.rows.count)
                let secondsLength = Double(length) / 1e9
                let active = length == 0 ? 0 : Double(busy) / Double(length) * 100
                let activeIO = length == 0 ? 0 : Double(busyIO) / Double(length) * 100
                let concurrency = length == 0 ? 0 : Double(dTime) / Double(length)
                let latency = dOps == 0 ? "—" : String(format: "%.3f", Double(dTime) / Double(dOps) / 1e6)
                let readRate = secondsLength == 0 ? 0 : Double(rBytes) / 1e6 / secondsLength
                let writeRate = secondsLength == 0 ? 0 : Double(wBytes) / 1e6 / secondsLength
                traceOps += tOps
                driverOps += dOps
                traceBytes += tBytes
                driverBytes += rBytes + wBytes
                report.line("  \(phaseName(g.index)) | \(String(format: "%.0f", secondsLength))초 | \(f1(active))% | \(f1(activeIO))% | \(f1(clippedMean))%"
                    + " | \(f2(concurrency)) | \(f1(readRate))·\(f1(writeRate)) | \(latency) | \(comma(tOps))·\(comma(dOps)) | \(ms(flush)) | \(ms(trim))")
                phaseLines += "\(g.index)\t\(phaseName(g.index))\t\(String(format: "%.3f", secondsLength))\t\(disk.bsd)\t\(f2(active))\t\(f2(activeIO))"
                    + "\t\(f2(clippedMean))\t\(String(format: "%.4f", concurrency))\t\(f2(readRate))\t\(f2(writeRate))\t\(latency)\t\(tOps)\t\(dOps)"
                    + "\t\(mb(tBytes))\t\(mb(rBytes + wBytes))\t\(ms(busy))\t\(ms(flush))\t\(ms(trim))\n"
            }
            report.line("  모두: 작업 추적 \(comma(traceOps)) · 드라이버 \(comma(driverOps)) (\(percent(traceOps, driverOps))) · 바이트 추적 \(mb(traceBytes)) MB · 드라이버 \(mb(driverBytes)) MB (\(percent(traceBytes, driverBytes)))")
            if mode != .load {
                histogram(mine)
            }
        }
        writeText(directory + "/phases.tsv", phaseLines)

        // 캐시 비우기·TRIM (내장 SSD)
        if let ssd = engine.map.internalSSD, engine.ssdEvents {
            let rows = samples.filter { $0.disk == ssd }
            if !rows.isEmpty {
                let io = rows.reduce(UInt64(0)) { $0 + $1.busyIO }
                let flush = rows.reduce(UInt64(0)) { $0 + $1.flush }
                let trim = rows.reduce(UInt64(0)) { $0 + $1.trim }
                report.line("")
                report.line("== 캐시 비우기·TRIM (내장 SSD, SSD 드라이버 이벤트, \(rows.count)초)")
                report.line("  캐시 비우기 \(comma(engine.flushes))번 · 합 \(ms(engine.flushNs)) ms · 디스크 I/O 밖으로 더해진 바쁜 시간 \(ms(flush)) ms (활성에 넣음)")
                report.line("  TRIM 명령 \(comma(engine.trimSpans))번 · 합 \(ms(engine.trimSpanNs)) ms · 더 더해질 바쁜 시간 \(ms(trim)) ms (활성에 넣지 않음)")
                report.line("  디스크 I/O만의 바쁜 시간 \(ms(io)) ms → 캐시 비우기로 \(percent(flush, io)) 늘었고, TRIM까지 넣으면 \(percent(flush + trim, io)) 늘어남")
                if engine.flushEventsMissing {
                    report.line("  주의: 내장 SSD 전체 동기화 요청이 \(comma(engine.fullSyncsInternal))개인데 캐시 비우기 이벤트가 0번 → 이 macOS에서는 이벤트 뜻이 바뀐 것으로 보고 디스크 I/O만으로 잼")
                } else {
                    report.line("  캐시 비우기 이벤트 확인: 내장 SSD 전체 동기화 요청 \(comma(engine.fullSyncsInternal))개 · 캐시 비우기 시작 \(comma(engine.flushStarts))번")
                }
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
    }

    /// 실사용 기록: 1초 활성 %의 분포, 디스크 I/O만·TRIM까지 넣은 값, 어림값(자른 동시)과의 차이
    private func histogram(_ rows: [DiskSample]) {
        let edges: [(String, Double, Double)] = [("0%", 0, 0.05), ("~1%", 0.05, 1), ("1~5%", 1, 5), ("5~20%", 5, 20),
                                                  ("20~50%", 20, 50), ("50~90%", 50, 90), ("90%~", 90, 1000)]
        let counts = edges.map { e in rows.filter { $0.active >= e.1 && $0.active < e.2 }.count }
        let text = zip(edges, counts).map { "\($0.0) \($1)" }.joined(separator: " · ")
        report.line("  1초 활성 분포 (\(rows.count)초): \(text)")
        func spread(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "—" }
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            return "평균 \(f1(mean))% · 중앙 \(f1(sorted[sorted.count / 2]))% · 90% \(f1(sorted[sorted.count * 9 / 10]))% · 최대 \(f1(sorted[sorted.count - 1]))%"
        }
        report.line("  활성: " + spread(rows.map { $0.active }) + " · 캐시 비우기가 있던 1초 \(rows.filter { $0.flush > 0 }.count)번")
        report.line("  디스크 I/O만: " + spread(rows.map { $0.activeIO }))
        report.line("  TRIM까지 넣으면: " + spread(rows.map { $0.activeWithTrim }) + " · TRIM이 있던 1초 \(rows.filter { $0.trim > 0 }.count)번")
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
    report.line("== DiskActiveProbe \(title) · \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))")
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

    switch acquireTrace(events: 262_144, filter: { try engine.setFilter(ssd: true) }) {
    case .acquired(let cleaned):
        if cleaned { report.line("▶ 소유자 없이 남은 추적이 있어 먼저 정리함") }
    case .busy(let owner):
        report.line("▶ 추적 켜기: 다른 도구가 사용 중 · \(owner). 그 도구가 끝난 뒤 다시 실행")
        return 3
    case .failed(let text):
        report.line("▶ 추적 켜기: \(text)")
        report.line("추적 상태: \(traceState())")
        return 2
    }
    installSignalHandlers()
    installCrashRelease()
    if let i = try? Kdebug.info() {
        report.line("▶ 추적 켜기: 성공 · 커널 버퍼 \(comma(Int(i.events)))개 (\(String(format: "%.1f", Double(i.events) * 64 / 1_048_576)) MiB)"
            + (Timebase.continuous ? " · 연속 시각" : " · 절대 시각") + " · SSD 드라이버 이벤트 받음(캐시 비우기·TRIM)")
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
