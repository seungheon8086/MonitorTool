// DiskActiveProbe: 디스크 활성 시간(요청이 하나라도 걸려 있던 시간 비율)을 커널 추적으로 물리 디스크별로 잰다.
// 명령: check | load [SD 경로] | live | record <분> | hold … | state | stamp | status | reset   (root 필요, run.sh로 실행)
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
_ = stopRequested   // 신호 처리기보다 먼저 초기화

/// 충돌 신호를 받았을 때 쓰는 글 (신호 처리기 안에서 힙을 쓰지 않으려고 미리 만든다)
let crashNote: [UInt8] = Array("\n▶ 비정상 종료: 커널 추적을 끄고 해제함\n".utf8)

// MARK: - 출력

final class Report {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(path: String?) {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        }
    }

    func line(_ s: String = "") {
        lock.lock()
        defer { lock.unlock() }
        print(s)
        handle?.write((s + "\n").data(using: .utf8)!)
    }

    func close() { try? handle?.close() }
}

func writeText(_ path: String, _ text: String) {
    FileManager.default.createFile(atPath: path, contents: text.data(using: .utf8))
}

func comma(_ n: UInt64) -> String {
    let s = String(n)
    var out = ""
    for (i, c) in s.enumerated() {
        if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
        out.append(c)
    }
    return out
}

func comma(_ n: Int) -> String { comma(UInt64(max(n, 0))) }
func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1e6) }
func mb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1e6) }
func seconds(_ ns: UInt64) -> String { String(format: "%.2f초", Double(ns) / 1e9) }

/// 음수가 될 수 있는 차이는 0으로 (UInt64 뺄셈이 넘치면 멈추므로)
func minus(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }

func percent(_ part: UInt64, _ whole: UInt64) -> String {
    whole == 0 ? "—" : String(format: "%.1f%%", Double(part) / Double(whole) * 100)
}

// MARK: - 시스템 정보

func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buf = [CChar](repeating: 0, count: size + 1)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

func processName(_ pid: Int32) -> String {
    let s = run("/bin/ps", ["-o", "comm=", "-p", String(pid)])
    return s.isEmpty ? "끝난 프로세스" : (s as NSString).lastPathComponent
}

func describe(_ i: KBufInfo) -> String {
    let owner = i.ownerPid > 0 ? "\(processName(i.ownerPid))(\(i.ownerPid))" : "없음"
    var parts = ["소유 \(owner)", "버퍼 \(comma(Int(i.events)))개", i.recordingOff ? "기록 꺼짐" : "기록 켜짐"]
    if i.flags & KD.flagTypeFilter != 0 { parts.append("형식 필터 켜짐") }
    if i.flags & KD.flagContinuous != 0 { parts.append("연속 시각") }
    if i.flags & KD.flagWrapped != 0 { parts.append("넘침 있음") }
    return parts.joined(separator: " · ")
}

func traceState() -> String {
    do { return describe(try Kdebug.info()) } catch { return "\(error)" }
}

func powermetricsState() -> String {
    let pids = run("/usr/bin/pgrep", ["-x", "powermetrics"]).split(separator: "\n").joined(separator: ", ")
    return pids.isEmpty ? "실행 안 함" : "실행 중 (pid \(pids))"
}

func firstLine(_ s: String) -> String {
    s.split(separator: "\n").first.map { String($0) } ?? "(출력 없음)"
}

func diskLabel(_ id: UInt64, _ map: DiskMap) -> String {
    guard let d = map.disks[id] else { return "알 수 없는 장치" }
    return "\(d.bsd) \(d.name)" + (d.isVirtual ? " (가상)" : "")
}

func devText(_ dev: Int32) -> String { "\((dev >> 24) & 0xff),\(dev & 0xffffff)" }

func installSignalHandlers() {
    signal(SIGINT) { _ in stopRequested = 1 }
    signal(SIGTERM) { _ in stopRequested = 1 }
    signal(SIGHUP) { _ in stopRequested = 1 }
}

/// 커널 추적을 끄고 해제한다. 충돌 신호 처리기에서 부르므로 힙을 쓰지 않는다 (KERN_KDEBUG 24 > KDENABLE 3 · KDREMOVE 7)
func emergencyRelease() {
    var mib: (Int32, Int32, Int32, Int32) = (CTL_KERN, 24, 3, 0)
    var length = 0
    withUnsafeMutablePointer(to: &mib) { tuple in
        tuple.withMemoryRebound(to: Int32.self, capacity: 4) { m in
            _ = sysctl(m, 4, nil, &length, nil, 0)
            m[2] = 7
            _ = sysctl(m, 3, nil, &length, nil, 0)
        }
    }
}

/// 추적을 켠 뒤에 부른다: 충돌(배열 범위 밖 등)로 끝나도 추적이 켜진 채 남지 않게 한다
func installCrashRelease() {
    for s in [SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE] {
        signal(s) { _ in
            emergencyRelease()
            crashNote.withUnsafeBufferPointer { _ = write(2, $0.baseAddress, $0.count) }
            _exit(70)
        }
    }
}

// MARK: - 1단계 check

struct Snapshot {
    var busy: UInt64 = 0
    var ops: UInt64 = 0
    var bytes: UInt64 = 0
}

func runCheck(directory: String) -> Int32 {
    let report = Report(path: directory + "/check.txt")
    defer { report.close() }
    guard getuid() == 0 else {
        report.line("관리자 권한 필요 (sudo ./run.sh check)")
        return 1
    }

    let started = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
    report.line("== DiskActiveProbe 1단계 (check) · \(started)")
    report.line("\(ProcessInfo.processInfo.operatingSystemVersionString) · \(sysctlString("hw.model"))")
    let tailspinBefore = run("/usr/bin/tailspin", ["info"])
    writeText(directory + "/tailspin-before.txt", tailspinBefore)
    report.line("추적 상태 (시작 전): \(traceState())")
    report.line("tailspin (시작 전): \(firstLine(tailspinBefore))")
    let powerBefore = powermetricsState()
    report.line("powermetrics (시작 전): \(powerBefore)")

    let map = DiskMap()
    report.line("물리 디스크")
    for d in map.disks.values.sorted(by: { $0.bsd < $1.bsd }) {
        report.line("  \(d.bsd) · \(d.name) · \(d.interconnect) · \(d.location)" + (d.isVirtual ? " · 가상" : ""))
    }

    // 추적 켜기: 첫 설정 명령(버퍼 크기)이 소유권을 가져온다.
    // 남은 플래그를 끈다: 버퍼가 차도 멈추지 않고(잃은 이벤트 표시), 시각은 mach_absolute_time, 특정 이벤트에서 멈추지 않음
    var owning = false
    do {
        try Kdebug.setBuffer(events: 262_144)
        owning = true
        try Kdebug.clearFlags(KD.flagNoWrap | KD.flagContinuous | KD.flagMatchDisable)
        try Kdebug.setup()
        try Kdebug.setTypeFilter([KD.cscDiskIO, KD.cscIoctl] + KD.observedKinds.keys.sorted())
        try Kdebug.enable(true)
    } catch {
        report.line("▶ 추적 켜기: \(error)")
        if owning { try? Kdebug.remove() }
        report.line("추적 상태: \(traceState())")
        return 2
    }
    installSignalHandlers()
    installCrashRelease()
    var bufferText = ""
    if let i = try? Kdebug.info() {
        Timebase.continuous = i.flags & KD.flagContinuous != 0
        bufferText = " · 버퍼 \(comma(Int(i.events)))개 (\(String(format: "%.1f", Double(i.events) * 64 / 1_048_576)) MiB)"
            + (i.flags & KD.flagTypeFilter != 0 ? " · 형식 필터 켜짐" : " · 형식 필터 꺼짐")
            + (Timebase.continuous ? " · 연속 시각" : " · 절대 시각")
    }
    report.line("")
    report.line("▶ 추적 켜기: 성공" + bufferText)
    report.line("▶ 부하 (약 16초)")

    let log = PhaseLog()
    let loadThread = Thread {
        runCheckLoad(directory: directory, map: map, log: log) { report.line("  \($0)") }
    }
    loadThread.start()

    // 읽기: 0.1초마다. 디스크 I/O·디스크 명령·잃은 이벤트만 남긴다.
    let reader = TraceReader(capacity: 262_144)
    var events: [TraceEvent] = []
    events.reserveCapacity(300_000)
    var otherEvents = 0
    var kindCounts: [UInt32: Int] = [:]
    var reads = 0
    var mostPerRead = 0
    var readerCPU: UInt64 = 0
    var readError: String?
    var finishedAt: UInt64?

    func drain() throws -> Int {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let n = try reader.read { e in
            kindCounts[e.csc, default: 0] += 1
            if e.csc == KD.cscDiskIO || e.csc == KD.cscIoctl || e.eventID == KD.lostEvents || KD.observedKinds[e.csc] != nil {
                events.append(e)
            } else {
                otherEvents += 1
            }
        }
        readerCPU += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0
        reads += 1
        mostPerRead = max(mostPerRead, n)
        return n
    }

    while true {
        usleep(100_000)
        do { _ = try drain() } catch { readError = "\(error)"; break }
        if stopRequested != 0 { break }
        if log.isFinished {
            if let t = finishedAt {
                if minus(Timebase.now(), t) > 1_000_000_000 { break }
            } else {
                finishedAt = Timebase.now()
            }
        }
    }

    // 끄기 → 남은 이벤트 비우기 → 해제 (Ctrl-C여도 여기까지 온다)
    try? Kdebug.enable(false)
    for _ in 0..<20 {
        guard readError == nil, let n = try? drain(), n > 0 else { break }
    }
    var releaseText = "성공"
    do { try Kdebug.remove() } catch { releaseText = "\(error)" }
    let afterRelease = traceState()
    sleep(2)
    let afterWait = traceState()
    report.line("▶ 추적 해제: \(releaseText)")
    report.line("  직후: \(afterRelease)")
    report.line("  2초 뒤: \(afterWait)")
    if let readError { report.line("  읽기 중단: \(readError)") }
    if stopRequested != 0 { report.line("  중단 요청으로 일찍 끝냄") }
    var waited = 0
    while !log.isFinished && waited < 200 {
        usleep(50_000)
        waited += 1
    }
    let powerAfter = powermetricsState()
    report.line("powermetrics (끝난 뒤): \(powerAfter)")
    let tailspinAfter = run("/usr/bin/tailspin", ["info"])
    writeText(directory + "/tailspin-after.txt", tailspinAfter)
    report.line("tailspin (끝난 뒤): \(firstLine(tailspinAfter))")

    analyze(events: events, marks: log.all, map: map, report: report, directory: directory,
            reads: reads, mostPerRead: mostPerRead, readerCPU: readerCPU, otherEvents: otherEvents,
            kindCounts: kindCounts, powerBefore: powerBefore, powerAfter: powerAfter, afterWait: afterWait)

    let ktraceLog = run("/usr/bin/log", ["show", "--last", "3m", "--style", "compact",
                                         "--predicate", "eventMessage CONTAINS \"ktrace:\""])
    writeText(directory + "/ktrace-log.txt", ktraceLog)
    let logLines = ktraceLog.split(separator: "\n").filter { $0.contains("ktrace:") }
    report.line("")
    report.line("== 커널 기록 (ktrace 소유권 변화, 최근 3분 \(logLines.count)줄)")
    for l in logLines.suffix(8) { report.line("  \(l)") }
    return 0
}

func analyze(events: [TraceEvent], marks: [PhaseMark], map: DiskMap, report: Report, directory: String,
             reads: Int, mostPerRead: Int, readerCPU: UInt64, otherEvents: Int, kindCounts: [UInt32: Int],
             powerBefore: String, powerAfter: String, afterWait: String) {
    var meter = BusyMeter()
    var keyDev: [UInt64: Int32] = [:]
    var devStarts: [Int32: UInt64] = [:]
    var devMatched: [Int32: UInt64] = [:]
    var durations: [Int: [UInt64: [UInt64]]] = [:]
    var starts = 0, dones = 0, ioctls = 0
    var syncOptions: [UInt64: Int] = [:]       // 동기화 요청(DKIOCSYNCHRONIZE) 옵션 → 수 (2 = 장벽)
    var trimRanges = 0
    var trimBytes: UInt64 = 0
    var observed: [UInt32: [UInt32: Int]] = [:] // 관찰 종류 → eventID → 수
    var snapshots: [[UInt64: Snapshot]] = []

    // 커널이 시각 순서로 합쳐 주지만, 거꾸로 된 것이 있으면 세고 안정 정렬한다
    var outOfOrder = 0
    if events.count > 1 {
        for i in 1..<events.count where events[i].time < events[i - 1].time { outOfOrder += 1 }
    }
    var ordered = events
    if outOfOrder > 0 {
        let indexed = events.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }
        ordered = indexed.map { $0.element }
    }

    func phaseIndex(_ t: UInt64) -> Int {
        guard marks.count >= 2 else { return -1 }
        for i in 0..<(marks.count - 1) where t >= marks[i].time && t < marks[i + 1].time { return i }
        return -1
    }

    func snapshot(at t: UInt64) {
        var s: [UInt64: Snapshot] = [:]
        for id in Set(map.disks.keys).union(meter.disks.keys) {
            let d = meter.disks[id]
            s[id] = Snapshot(busy: meter.busyNs(disk: id, at: t), ops: d?.completed ?? 0, bytes: d?.bytes ?? 0)
        }
        snapshots.append(s)
    }

    var next = 0
    for e in ordered {
        while next < marks.count && marks[next].time <= e.time {
            snapshot(at: marks[next].time)
            next += 1
        }
        if e.csc == KD.cscDiskIO {
            if e.code & KD.dkioDone == 0 {
                starts += 1
                let dev = Int32(truncatingIfNeeded: e.arg2)
                meter.start(key: e.arg1, disk: map.devices[dev]?.disk ?? 0, bytes: e.arg4, at: e.time)
                keyDev[e.arg1] = dev
                devStarts[dev, default: 0] += 1
            } else {
                dones += 1
                if let r = meter.done(key: e.arg1, at: e.time) {
                    if let dev = keyDev.removeValue(forKey: e.arg1) { devMatched[dev, default: 0] += 1 }
                    let p = phaseIndex(e.time)
                    if p >= 0 { durations[p, default: [:]][r.disk, default: []].append(r.duration) }
                }
            }
        } else if e.csc == KD.cscIoctl {
            // 시작·끝이 아니라 한 번 찍히는 이벤트 (1단계 관찰)
            ioctls += 1
            if e.eventID == KD.syncRequest {
                syncOptions[e.arg3, default: 0] += 1
            } else if e.eventID == KD.trimRange {
                trimRanges += 1
                trimBytes += e.arg3
            }
        } else if e.eventID == KD.lostEvents {
            meter.lose(at: e.time)
        } else if KD.observedKinds[e.csc] != nil {
            observed[e.csc, default: [:]][e.eventID, default: 0] += 1
        }
    }
    while next < marks.count {
        snapshot(at: marks[next].time)
        next += 1
    }

    // 이벤트
    let matched = devMatched.values.reduce(0, +)
    report.line("")
    report.line("== 이벤트")
    report.line("읽기 \(comma(reads))번 · 한 번에 최대 \(comma(mostPerRead))개 · 읽기 CPU \(ms(readerCPU)) ms")
    report.line("디스크 I/O 시작 \(comma(starts)) · 끝 \(comma(dones)) · 짝 맞음 \(comma(matched)) (\(percent(matched, UInt64(starts))))"
        + " · 시작 못 본 끝 \(comma(meter.unmatchedDone)) · 끝 못 본 시작 \(comma(meter.pendingCount))"
        + " · 같은 열쇠 다시 시작 \(comma(meter.replacedStart)) · 잃음 \(comma(meter.lossCount))번")
    report.line("버린 요청 \(comma(meter.dropped)) · 시각이 거꾸로 된 이벤트 \(comma(outOfOrder))")
    let syncText = syncOptions.keys.sorted().map { "옵션 \($0) \(comma(syncOptions[$0]!))" }.joined(separator: " · ")
    report.line("디스크 명령 이벤트 \(comma(ioctls)): 동기화 요청 \(comma(syncOptions.values.reduce(0, +)))개"
        + (syncText.isEmpty ? "" : " (\(syncText))") + " · TRIM 범위 \(comma(trimRanges))개 \(mb(trimBytes)) MB · 그 밖의 이벤트 \(comma(otherEvents))")
    let kindText = kindCounts.sorted { $0.value > $1.value }.prefix(12)
        .map { String(format: "0x%04x", $0.key) + " \(comma($0.value))" }.joined(separator: " · ")
    report.line("종류별 (class<<8|subclass): \(kindText)")

    // 관찰 종류: 드라이버 단계 저장장치 이벤트
    report.line("")
    report.line("== 저장장치 쪽 다른 이벤트 (관찰만)")
    if observed.isEmpty {
        report.line("  없음")
    }
    for csc in observed.keys.sorted() {
        let ids = observed[csc]!
        let total = ids.values.reduce(0, +)
        let top = ids.sorted { $0.value > $1.value }.prefix(10)
            .map { String(format: "0x%08x", $0.key) + " \(comma($0.value))" }.joined(separator: " · ")
        report.line("  \(KD.observedKinds[csc] ?? "?") (\(String(format: "0x%04x", csc))): \(comma(total))개 · \(top)")
    }

    // 장치 → 물리 디스크
    report.line("")
    report.line("== 장치 → 물리 디스크 (시작 이벤트가 있던 장치)")
    var devLines = "major\tminor\tbsd\tdisk\tstarts\tmatched\n"
    var unknown = 0
    for (dev, n) in devStarts.sorted(by: { $0.value > $1.value }) {
        let entry = map.devices[dev]
        let nonDisk = DiskMap.nonDiskName(dev)
        let target = entry?.disk.map { diskLabel($0, map) } ?? (nonDisk != nil ? "디스크 아님" : "물리 디스크 못 찾음")
        if entry?.disk == nil && nonDisk == nil { unknown += 1 }
        report.line("  \(entry?.bsd ?? nonDisk ?? "알 수 없음") (\(devText(dev))) → \(target) · 시작 \(comma(n)) · 짝 \(comma(devMatched[dev] ?? 0))")
        devLines += "\((dev >> 24) & 0xff)\t\(dev & 0xffffff)\t\(entry?.bsd ?? "")\t\(entry?.disk.flatMap { map.disks[$0]?.bsd } ?? "")\t\(n)\t\(devMatched[dev] ?? 0)\n"
    }
    writeText(directory + "/devices.tsv", devLines)

    // 단계별
    var phaseLines = "phase\tseconds\tdisk\tvirtual\tbusy_ms\tactive_pct\ttrace_ops\ttrace_bytes\tdriver_ops\tdriver_bytes\tdriver_time_ms\tdriver_concurrency\tp50_ms\tp90_ms\tdriver_avg_ms\n"
    var summary: [String] = []
    let activeDisks = Set(meter.disks.keys).union(map.disks.keys).sorted { diskLabel($0, map) < diskLabel($1, map) }
    if marks.count >= 2 && snapshots.count == marks.count {
        for id in activeDisks {
            var rows: [String] = []
            var traceBytesTotal: UInt64 = 0
            var driverBytesTotal: UInt64 = 0
            for p in 0..<(marks.count - 1) {
                let length = minus(marks[p + 1].time, marks[p].time)
                let a = snapshots[p][id] ?? Snapshot()
                let b = snapshots[p + 1][id] ?? Snapshot()
                let busy = minus(b.busy, a.busy)
                let ops = minus(b.ops, a.ops)
                let bytes = minus(b.bytes, a.bytes)
                let s0 = marks[p].stats[id]
                let s1 = marks[p + 1].stats[id]
                let dOps = minus(s1?.ops ?? 0, s0?.ops ?? 0)
                let dBytes = minus(s1?.bytes ?? 0, s0?.bytes ?? 0)
                let dTime = minus(s1?.time ?? 0, s0?.time ?? 0)
                if ops == 0 && dOps == 0 && busy == 0 { continue }
                traceBytesTotal += bytes
                driverBytesTotal += dBytes
                let sorted = (durations[p]?[id] ?? []).sorted()
                let p50 = sorted.isEmpty ? "—" : ms(sorted[sorted.count / 2])
                let p90 = sorted.isEmpty ? "—" : ms(sorted[sorted.count * 9 / 10])
                let concurrency = length == 0 ? 0 : Double(dTime) / Double(length)
                let avg = dOps == 0 ? "—" : ms(dTime / dOps)
                rows.append("  \(marks[p].name) | \(seconds(length)) | \(percent(busy, length)) | \(String(format: "%.3f", concurrency))"
                    + " | \(comma(ops))·\(comma(dOps)) | \(mb(bytes))·\(mb(dBytes)) | \(p50)·\(p90)·\(avg)")
                let virtual = map.disks[id]?.isVirtual == true ? 1 : 0
                let active = length == 0 ? 0 : Double(busy) / Double(length) * 100
                phaseLines += "\(marks[p].name)\t\(String(format: "%.3f", Double(length) / 1e9))\t\(map.disks[id]?.bsd ?? "unknown")\t\(virtual)"
                    + "\t\(ms(busy))\t\(String(format: "%.2f", active))\t\(ops)\t\(bytes)\t\(dOps)\t\(dBytes)\t\(ms(dTime))"
                    + "\t\(String(format: "%.4f", concurrency))\t\(p50)\t\(p90)\t\(avg)\n"
                if map.disks[id]?.isVirtual != true && marks[p].name.contains("동시") {
                    summary.append("\(marks[p].name) (\(map.disks[id]?.bsd ?? "?")): 활성 \(percent(busy, length)) · 동시 \(String(format: "%.2f", concurrency))")
                }
            }
            if rows.isEmpty { continue }
            report.line("")
            report.line("== 단계별 · \(diskLabel(id, map))")
            report.line("  단계 | 길이 | 활성(추적) | 동시(드라이버) | 작업 추적·드라이버 | MB 추적·드라이버 | 응답 ms 추적 중앙·90%·드라이버 평균")
            for r in rows { report.line(r) }
            if map.disks[id]?.isVirtual != true && driverBytesTotal > 0 {
                summary.insert("바이트 대조 (\(map.disks[id]?.bsd ?? "?"), 모든 단계): 추적 \(mb(traceBytesTotal)) MB · 드라이버 \(mb(driverBytesTotal)) MB (\(percent(traceBytesTotal, driverBytesTotal)))", at: 0)
            }
        }
    } else {
        report.line("")
        report.line("단계 기록이 모자라 단계별 표를 만들지 못함 (단계 \(marks.count)개, 기준점 \(snapshots.count)개)")
    }
    writeText(directory + "/phases.tsv", phaseLines)

    // 요약
    report.line("")
    report.line("== 요약")
    report.line("추적 자리: 얻음 · 해제 2초 뒤 \(afterWait)")
    report.line("짝 맞음: \(comma(matched)) / 시작 \(comma(starts)) (\(percent(matched, UInt64(starts)))) · 잃음 \(comma(meter.lossCount))번")
    report.line(unknown == 0 ? "장치 대응: 시작 이벤트가 있던 장치 \(devStarts.count)개 모두 물리 디스크에 닿음"
                             : "장치 대응: 물리 디스크를 못 찾은 장치 \(unknown)개")
    for s in summary { report.line(s) }
    report.line("powermetrics: \(powerBefore) → \(powerAfter)")
    report.line("읽기 CPU: \(ms(readerCPU)) ms (이벤트 \(comma(events.count + otherEvents))개)")

    // 원본 이벤트 (커밋하지 않음)
    var text = "time_ns\tcpu\tdebugid\targ1\targ2\targ3\targ4\tthread\n"
    text.reserveCapacity(min(events.count, 2_000_000) * 90)
    for e in events {
        text += "\(e.time)\t\(e.cpu)\t\(String(e.debugid, radix: 16))\t\(String(e.arg1, radix: 16))\t\(e.arg2)\t\(e.arg3)\t\(e.arg4)\t\(e.thread)\n"
    }
    writeText(directory + "/events.tsv", text)
}

// MARK: - status · reset

func runStatus() -> Int32 {
    guard getuid() == 0 else { print("관리자 권한 필요 (sudo ./run.sh status)"); return 1 }
    print("ktrace: \(stateLine())")
    print("추적 상태: \(traceState())")
    print("tailspin: \(firstLine(run("/usr/bin/tailspin", ["info"])))")
    print("powermetrics: \(powermetricsState())")
    return 0
}

/// 비정상 종료로 남은 추적만 정리한다. 살아 있는 소유자가 있으면 손대지 않는다.
func runReset() -> Int32 {
    guard getuid() == 0 else { print("관리자 권한 필요 (sudo ./run.sh reset)"); return 1 }
    let info: KBufInfo
    do { info = try Kdebug.info() } catch { print("\(error)"); return 1 }
    print("추적 상태: \(describe(info))")
    if info.ownerPid > 0 {
        let name = processName(info.ownerPid)
        print(name == "tailspind" ? "정리할 것 없음 · tailspind 사용 중 (정상)" : "손대지 않음 · \(name)(\(info.ownerPid)) 사용 중")
        return 0
    }
    if info.recordingOff && info.flags & KD.flagBufInit == 0 {
        print("정리할 것 없음")
        return 0
    }
    do {
        try Kdebug.enable(false)
        try Kdebug.remove()
    } catch {
        print("\(error)")
        return 1
    }
    print("정리함 · 남은 추적 해제")
    sleep(2)
    print("추적 상태 (2초 뒤): \(traceState())")
    return 0
}

/// 한 줄 상태: 커널 변수(ktrace.*)를 먼저 읽고(끝난 소유자가 보이게), 그다음 버퍼 상태(KDGETBUF, root만)
func stateLine() -> String {
    let k = KtraceState.read()
    var parts = [k.stateName,
                 "소유 " + (k.owningPid > 0 ? "\(processName(k.owningPid))(\(k.owningPid))" : "없음"),
                 "배경 도구 " + (k.backgroundPid > 0 ? "\(processName(k.backgroundPid))(\(k.backgroundPid))" : "없음"),
                 "마지막 설정 " + (k.configuredBy.isEmpty ? "—" : k.configuredBy)]
    if let b = k.blessedPreempt { parts.append("blessed_preempt \(b)") }
    if getuid() == 0, let i = try? Kdebug.info() {
        parts.append("버퍼 \(comma(Int(i.events)))개")
        parts.append(i.recordingOff ? "기록 꺼짐" : "기록 켜짐")
        if i.ownerPid <= 0 && i.flags & KD.flagBufInit != 0 { parts.append("소유자 없이 남은 추적") }
    }
    return parts.joined(separator: " · ")
}

/// 지금 시각 (시:분:초.밀리초). coexist.sh의 시간표에 쓴다
func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "check" where args.count > 2:
    exit(runCheck(directory: args[2]))
case "load" where args.count > 2:
    exit(runSession(mode: .load, directory: args[2], minutes: nil, sdPath: args.count > 3 ? args[3] : nil))
case "live" where args.count > 2:
    exit(runSession(mode: .live, directory: args[2], minutes: nil, sdPath: nil))
case "record" where args.count > 3:
    exit(runSession(mode: .record, directory: args[2], minutes: max(Int(args[3]) ?? 10, 1), sdPath: nil))
case "hold" where args.count > 5:
    // hold <결과 폴더> <이름표> <초> <비켜주기 0|1> [다시 잡기 전 초]
    exit(runHold(directory: args[2], label: args[3], limit: max(Int(args[4]) ?? 10, 1), yieldOn: args[5] == "1",
                 graceSeconds: args.count > 6 ? (Int(args[6]) ?? 10) : 10))
case "state":
    print(stateLine())
    exit(0)
case "stamp":
    print(stamp())
    exit(0)
case "status":
    exit(runStatus())
case "reset":
    exit(runReset())
default:
    print("사용법: diskactiveprobe check <결과 폴더> | load <결과 폴더> [SD 경로] | live <결과 폴더> | record <결과 폴더> <분>"
        + " | hold <결과 폴더> <이름표> <초> <비켜주기 0|1> [다시 잡기 전 초] | state | stamp | status | reset   (sudo ./run.sh로 실행)")
    exit(2)
}
