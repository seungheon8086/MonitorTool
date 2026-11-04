// 3단계: 공존 시험용 '쥐고 있기'(hold). coexist.sh가 여러 개를 차례로 띄운다.
// 추적을 잡고 1초마다 디스크별 활성 %를 남긴다. 추적을 못 쓰는 1초는 드라이버 통계 어림값을 '추정'으로 남긴다.
// - 시작할 때 소유자 없이 남은 추적이 있으면 정리하고 잡는다 (acquireTrace)
// - 다른 도구가 쓰는 중이면 손대지 않고 추정으로 버티다 2초마다 다시 잡아 본다
// - 읽기가 EBUSY이거나 소유자가 바뀌면(밀려남) 추정으로 바꾸고 다시 잡아 본다
// - 비켜주기를 켜면: 추적 중에는 추적 도구(fs_usage·xctrace 등)의 실행 이벤트를 보는 즉시 해제한다.
//   해제한 동안에는 그 pid가 살아 있는지만 보고, 끝나고 grace초가 지나면 잡기 직전에 프로세스 목록을 한 번 본 뒤
//   (비켜준 동안 켜진 도구, 시작 전부터 돌던 도구) 다시 잡는다. 프로세스 목록은 한 번에 약 2.5 ms라 1초마다 보지 않는다
// 붙일 때 보조 프로그램이 할 일을 여기서 먼저 시험한다.
import Foundation

/// 비켜줄 추적 도구 (프로세스 이름, p_comm 16자 안).
/// spindump는 늘 떠 있는 시스템 데몬이라 넣지 않는다 (3단계 첫 시험: pid 795가 내내 있었고 추적과 부딪히지 않음)
let traceToolNames: Set<String> = ["fs_usage", "sc_usage", "latency", "ktrace", "xctrace", "Instruments", "sysdiagnose"]

/// 프로세스가 아직 있는지 (root라 권한 문제는 없다)
func processAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

/// 지금 도는 프로세스 중 이름이 names에 든 것 (나는 빼고). sysctl KERN_PROC_ALL 한 번
func runningProcesses(named names: Set<String>) -> [(pid: Int32, name: String)] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = procs.count * stride
    let ok = procs.withUnsafeMutableBytes { raw -> Bool in
        sysctl(&mib, 4, raw.baseAddress, &size, nil, 0) == 0
    }
    guard ok else { return [] }
    let me = getpid()
    var out: [(pid: Int32, name: String)] = []
    for i in 0..<min(size / stride, procs.count) {
        let pid = procs[i].kp_proc.p_pid
        if pid == me || pid <= 0 { continue }
        var comm = procs[i].kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if names.contains(name) { out.append((pid: pid, name: name)) }
    }
    return out
}

/// 여러 프로세스가 한 파일에 덧붙여 쓰는 시간표 (줄 단위로 O_APPEND)
final class Timeline {
    private let fd: Int32
    private let label: String
    private let clock = DateFormatter()

    init(path: String, label: String) {
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        self.label = label
        clock.dateFormat = "HH:mm:ss.SSS"
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    func note(_ text: String) {
        let line = "\(clock.string(from: Date())) [\(label)] \(text)\n"
        print(line, terminator: "")
        guard fd >= 0 else { return }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// 1초 표본의 경계 시각. 추적 중이면 그 엔진(gen)이 이 시각의 누적값을 채운다
struct HoldTick {
    let k: Int
    let time: UInt64
    let wall: String
    let stats: [UInt64: DriverStats]
    let gen: Int?                       // 이 시각에 추적 중이던 엔진 번호 (추적이 아니면 nil)
    var totals: [UInt64: DiskTotals]?
}

/// 경계 시각을 모았다가 앞뒤가 모두 정해진 1초를 꺼낸다. 규칙은 hold_test.py와 같다
struct TickBook {
    private(set) var ticks: [HoldTick] = []

    mutating func add(_ t: HoldTick) {
        ticks.append(t)
    }

    mutating func fill(gen: Int, time: UInt64, totals: [UInt64: DiskTotals]) {
        if let i = ticks.firstIndex(where: { $0.gen == gen && $0.time == time && $0.totals == nil }) {
            ticks[i].totals = totals
        }
    }

    /// live = 지금 추적 중인 엔진 번호 (없으면 nil). 그 엔진이 아직 안 채운 시각에서 멈춘다
    mutating func ready(live: Int?) -> [(a: HoldTick, b: HoldTick)] {
        func settled(_ t: HoldTick) -> Bool { t.gen == nil || t.totals != nil || t.gen != live }
        var out: [(a: HoldTick, b: HoldTick)] = []
        while ticks.count >= 2 && settled(ticks[0]) && settled(ticks[1]) {
            out.append((a: ticks[0], b: ticks[1]))
            ticks.removeFirst()
        }
        return out
    }

    /// 두 경계가 같은 엔진으로 채워졌으면 추적 값을 쓸 수 있다
    static func traced(_ a: HoldTick, _ b: HoldTick) -> Bool {
        a.gen != nil && a.gen == b.gen && a.totals != nil && b.totals != nil
    }
}

final class Holder {
    let label: String
    let limit: Int                  // 초
    let yieldOn: Bool
    let grace: UInt64               // 추적 도구가 끝난 뒤 다시 잡기까지 (ns)
    private let timeline: Timeline
    private let report: Report
    private let samplesFile: LineWriter
    private let wallClock = DateFormatter()
    private var map = DiskMap()
    private var mapBuiltAt = Timebase.now()
    private var engine: Engine?
    private var gen = 0
    private var book = TickBook()
    private var nextTry: UInt64 = 0
    private var yieldedTo: String?
    private var yieldedPids: Set<Int32> = []    // 비켜준 도구들 (살아 있는 동안 기다린다)
    private var lastToolSeen: UInt64 = 0

    // 세기
    private var attempts = 0
    private var acquiredCount = 0
    private var cleanedCount = 0
    private var busyCount = 0
    private var failedCount = 0
    private var yields = 0
    private var waitsByScan = 0
    private var lostCount = 0
    private var execSeen = 0
    private var tracedSeconds = 0
    private var estimatedSeconds = 0
    private var scans = 0
    private var scanCPU: UInt64 = 0
    private var readerCPU: UInt64 = 0
    private var processCPU: UInt64 = 0
    private var eventsRead: UInt64 = 0
    private var reads = 0
    private var losses = 0
    private var flushes = 0
    private var trimSpans = 0

    init(directory: String, label: String, limit: Int, yieldOn: Bool, graceSeconds: Int) {
        self.label = label
        self.limit = limit
        self.yieldOn = yieldOn
        self.grace = UInt64(max(graceSeconds, 1)) * 1_000_000_000
        timeline = Timeline(path: directory + "/timeline.txt", label: label)
        report = Report(path: directory + "/hold-\(label).txt")
        samplesFile = LineWriter(path: directory + "/hold-\(label).tsv",
                                 header: "second\twall\tsource\tdisk\tactive_pct\tio_pct\tclipped_pct")
        wallClock.dateFormat = "HH:mm:ss"
    }

    func run() -> Int32 {
        installSignalHandlers()
        let usage0 = cpuSeconds()
        let started = Timebase.now()
        timeline.note("시작 · \(limit)초 · 비켜주기 \(yieldOn ? "켬 (도구가 끝나고 \(grace / 1_000_000_000)초 뒤 다시 잡음)" : "끔") · pid \(getpid())")
        tryAcquire(now: started)
        var k = 0
        var nextTick = started
        while stopRequested == 0 {
            let now = Timebase.now()
            if now >= nextTick {
                tick(k: k, at: now)
                if k >= limit { break }
                k += 1
                nextTick = started + UInt64(k) * 1_000_000_000
            }
            if engine != nil {
                readAndProcess()
            } else if now >= nextTry {
                tryAcquire(now: now)
            }
            emitReady()
            refreshMapIfNeeded(now)
            let left = minus(min(nextTick, Timebase.now() + 100_000_000), Timebase.now()) / 1000
            if left > 0 { usleep(useconds_t(min(left, 100_000))) }
        }
        if stopRequested != 0 { timeline.note("멈춤 요청 받음") }
        if let e = engine {
            drain(e)
            if let problem = releaseTrace() { timeline.note("해제 문제: \(problem)") }
            retire(e)
            engine = nil
            timeline.note("추적 해제 (끝)")
        }
        emitReady()
        samplesFile.close()
        summarize(cpu: cpuSeconds() - usage0, wall: Double(minus(Timebase.now(), started)) / 1e9)
        report.close()
        return 0
    }

    // MARK: 경계 시각과 표본

    private func tick(k: Int, at now: UInt64) {
        let g: Int? = engine != nil ? gen : nil
        book.add(HoldTick(k: k, time: now, wall: wallClock.string(from: Date()), stats: map.allStats(), gen: g, totals: nil))
        guard let e = engine else { return }
        e.addTick(now)
        // 다른 root 프로세스가 kperf로 소유자를 바꿨는지 (blessed_preempt)
        let s = KtraceState.read()
        if s.owningPid != getpid() {
            lose(e, reason: "소유자가 바뀜 → \(ownerText(s.owningPid, s))")
        }
    }

    private func emitReady() {
        for pair in book.ready(live: engine != nil ? gen : nil) {
            emit(pair.a, pair.b)
        }
    }

    private func emit(_ a: HoldTick, _ b: HoldTick) {
        let length = minus(b.time, a.time)
        let traced = TickBook.traced(a, b)
        var parts: [String] = []
        for d in map.physical {
            guard let s0 = a.stats[d.id], let s1 = b.stats[d.id] else { continue }
            let drv = difference(s1, s0)
            let concurrency = length == 0 ? 0 : Double(drv.time) / Double(length)
            let clipped = min(concurrency, 1) * 100
            var value = clipped
            var ioText = ""
            if traced, let t0 = a.totals, let t1 = b.totals {
                let x0 = t0[d.id] ?? DiskTotals()
                let x1 = t1[d.id] ?? DiskTotals()
                let busy = minus(x1.busyWithFlush, x0.busyWithFlush)
                let io = minus(x1.busy, x0.busy)
                value = length == 0 ? 0 : Double(busy) / Double(length) * 100
                ioText = f2(length == 0 ? 0 : Double(io) / Double(length) * 100)
            }
            samplesFile.write("\(a.k)\t\(a.wall)\t\(traced ? "trace" : "estimate")\t\(d.bsd)\t\(f2(value))\t\(ioText)\t\(f2(clipped))")
            parts.append("\(d.bsd) \(f1(value))%")
        }
        if traced { tracedSeconds += 1 } else { estimatedSeconds += 1 }
        print("\(a.wall) [\(label)] \(traced ? "추적" : "추정") " + parts.joined(separator: " · "))
        if a.k % 10 == 0 { samplesFile.flush() }
    }

    private func fill(_ produced: [(time: UInt64, totals: [UInt64: DiskTotals])], gen g: Int) {
        for p in produced { book.fill(gen: g, time: p.time, totals: p.totals) }
    }

    // MARK: 추적

    private func readAndProcess() {
        guard let e = engine else { return }
        do {
            try e.read()
        } catch {
            lose(e, reason: "읽기 실패 (\(error))")
            return
        }
        let execs = e.takeExecs().filter { traceToolNames.contains($0.name) && $0.pid != getpid() }
        for x in execs {
            execSeen += 1
            let lag = ms(minus(Timebase.now(), x.time))
            if yieldOn {
                timeline.note("추적 도구 실행 봄: \(x.name)(\(x.pid)) · 실행 이벤트에서 \(lag) ms 뒤")
                yieldNow(e, to: "\(x.name)(\(x.pid))", pid: x.pid, seenAt: x.time)
                return
            }
            timeline.note("추적 도구 실행 봄: \(x.name)(\(x.pid)) · 비켜주기 끔이라 그대로 쥠")
        }
        fill(e.process(until: minus(Timebase.now(), 20_000_000)), gen: gen)
        e.refreshMapIfNeeded()
    }

    /// 남은 이벤트를 읽고 이 엔진의 경계 시각을 모두 채운다
    private func drain(_ e: Engine) {
        try? Kdebug.enable(false)
        for _ in 0..<3 {
            if (try? e.read()) == nil { break }
        }
        fill(e.process(until: UInt64.max), gen: gen)
    }

    /// 엔진 하나가 쓴 비용을 더해 둔다
    private func retire(_ e: Engine) {
        readerCPU += e.readerCPU
        processCPU += e.processCPU
        eventsRead += e.eventsRead
        reads += e.reads
        losses += e.losses
        flushes += e.flushes
        trimSpans += e.trimSpans
    }

    private func yieldNow(_ e: Engine, to who: String, pid: Int32, seenAt: UInt64) {
        drain(e)
        let problem = releaseTrace()
        retire(e)
        engine = nil
        yields += 1
        yieldedTo = who
        if pid > 0 { yieldedPids.insert(pid) }
        lastToolSeen = Timebase.now()
        nextTry = lastToolSeen + 1_000_000_000
        let lag = ms(minus(Timebase.now(), seenAt))
        timeline.note("비켜줌: \(who) · 실행부터 해제까지 \(lag) ms" + (problem.map { " · 해제 문제: \($0)" } ?? "") + " → 추정")
    }

    private func lose(_ e: Engine, reason: String) {
        retire(e)
        engine = nil
        lostCount += 1
        let s = KtraceState.read()
        var cleanup = ""
        // 내가 아직 소유자로 남아 있으면(설정이 사라진 경우 등) 깨끗이 내려놓는다. 남의 것은 건드리지 않는다
        if s.owningPid == getpid() {
            cleanup = releaseTrace().map { " · 내 쪽 해제 문제: \($0)" } ?? " · 내 쪽 남은 설정 해제"
        }
        timeline.note("밀려남: \(reason) · 지금 \(s.stateName) · 소유 \(ownerText(s.owningPid, s))\(cleanup) → 추정, 2초 뒤 다시")
        nextTry = Timebase.now() + 2_000_000_000
    }

    /// 프로세스 목록에서 추적 도구 찾기 (한 번에 약 2.5 ms라 잡기 직전에만)
    private func scanTools() -> [(pid: Int32, name: String)] {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let tools = runningProcesses(named: traceToolNames)
        scanCPU += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0
        scans += 1
        return tools
    }

    private func tryAcquire(now: UInt64) {
        if yieldOn {
            // 비켜준 도구가 아직 살아 있으면 기다린다 (pid만 보므로 싸다)
            yieldedPids = yieldedPids.filter { processAlive($0) }
            if !yieldedPids.isEmpty {
                lastToolSeen = now
                nextTry = now + 1_000_000_000
                return
            }
            if yieldedTo != nil && minus(now, lastToolSeen) < grace {
                nextTry = lastToolSeen + grace
                return
            }
            // 잡기 직전에 한 번: 비켜준 동안 켜진 도구, 시작 전부터 돌던 도구
            let tools = scanTools()
            if !tools.isEmpty {
                let names = tools.map { "\($0.name)(\($0.pid))" }.joined(separator: " · ")
                waitsByScan += 1
                timeline.note("추적 도구가 도는 중이라 기다림: \(names) (프로세스 목록)")
                for t in tools { yieldedPids.insert(t.pid) }
                yieldedTo = names
                lastToolSeen = now
                nextTry = now + 1_000_000_000
                return
            }
        }
        attempts += 1
        switch acquireTrace(events: 262_144, filter: { try Kdebug.setTypeFilter(Engine.kinds(ssd: true)) }) {
        case .acquired(let cleaned):
            let e = Engine(ssdEvents: true)
            e.watchExecs = true
            gen += 1
            engine = e
            acquiredCount += 1
            if cleaned { cleanedCount += 1 }
            let after = yieldedTo.map { " · \($0)이(가) 끝나고 \(seconds(minus(now, lastToolSeen))) 뒤" } ?? ""
            timeline.note("추적 잡음" + (cleaned ? " · 소유자 없이 남은 추적을 먼저 정리함" : "") + after)
            yieldedTo = nil
            installCrashRelease()
        case .busy(let owner):
            busyCount += 1
            if busyCount == 1 || busyCount % 5 == 0 {
                timeline.note("못 잡음: 다른 도구 사용 중 · \(owner) → 추정, 2초마다 다시 (\(busyCount)번째)")
            }
            nextTry = now + 2_000_000_000
        case .failed(let text):
            failedCount += 1
            timeline.note("못 잡음: \(text) → 추정, 5초 뒤 다시")
            nextTry = now + 5_000_000_000
        }
    }

    private func refreshMapIfNeeded(_ now: UInt64) {
        if minus(now, mapBuiltAt) > 30_000_000_000 {
            map = DiskMap()
            mapBuiltAt = now
        }
    }

    // MARK: 보고

    private func summarize(cpu: Double, wall: Double) {
        report.line("== DiskActiveProbe 3단계 hold [\(label)] · \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))")
        report.line("설정: \(limit)초 · 비켜주기 \(yieldOn ? "켬 · 다시 잡기 전 \(grace / 1_000_000_000)초" : "끔") · pid \(getpid())")
        report.line("1초 표본 \(tracedSeconds + estimatedSeconds)개: 추적 \(tracedSeconds) · 추정 \(estimatedSeconds)")
        report.line("잡기: 시도 \(attempts) · 성공 \(acquiredCount) (남은 추적 정리 \(cleanedCount)) · 다른 도구 사용 중 \(busyCount) · 실패 \(failedCount)")
        report.line("비켜줌 \(yields)번 (실행 이벤트) · 프로세스 목록으로 기다림 \(waitsByScan)번 · 밀려남 \(lostCount)번 · 추적 도구 실행 이벤트 \(execSeen)번")
        let scanText = scans == 0 ? "없음" : "\(scans)번 · 한 번 평균 \(String(format: "%.0f", Double(scanCPU) / Double(scans) / 1000)) µs"
        report.line("CPU: 읽기 \(ms(readerCPU)) ms (\(comma(reads))번) · 처리 \(ms(processCPU)) ms · 프로세스 목록 \(scanText)"
            + " · 도구 전체 \(String(format: "%.2f", cpu))초 / \(String(format: "%.0f", wall))초")
        report.line("이벤트 \(comma(eventsRead))개 · 잃음 \(losses)번 · 캐시 비우기 \(comma(flushes))번 · TRIM 명령 \(comma(trimSpans))번")
        report.line("끝난 뒤 상태: \(KtraceState.read().stateName)")
    }
}

/// hold <결과 폴더> <이름표> <초> <비켜주기 0|1> [다시 잡기 전 초]
func runHold(directory: String, label: String, limit: Int, yieldOn: Bool, graceSeconds: Int) -> Int32 {
    guard getuid() == 0 else {
        print("관리자 권한 필요")
        return 1
    }
    return Holder(directory: directory, label: label, limit: limit, yieldOn: yieldOn, graceSeconds: graceSeconds).run()
}
