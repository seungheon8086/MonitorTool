// ResourceProbe: MonitorTool 가족이 쓰는 연산량·에너지·메모리를 재요. (2026-11-04)
//
// 사용법 (보통은 measure.sh가 불러요. 직접 쓸 때는 관리자 권한으로):
//   sudo ./rusage_probe <측정 초> <출력 폴더>
//
// 2초마다 프로세스 목록을 훑어서 아래 프로세스의 누적 사용량(proc_pid_rusage, RUSAGE_INFO_V6)을 읽고,
// 측정하는 동안 늘어난 양을 역할별로 더해요. macOS가 프로세스마다 쌓아 두는 값이라 측정 자체의 부담이 작아요.
//   앱            /Applications/MonitorTool.app/Contents/MacOS/MonitorTool
//   보조 프로그램  /Applications/MonitorTool.app/Contents/MacOS/MonitorToolHelper (root)
//   위젯 확장      /Applications/MonitorTool.app/Contents/PlugIns/MonitorToolWidget.appex 안의 실행 파일
//   powermetrics  보조 프로그램이 띄운 /usr/bin/powermetrics (root)
//   참고          WindowServer, chronod (다른 앱과 함께 쓰는 시스템 프로세스라 가족 합계에는 넣지 않아요)
// 측정 중에 새로 뜬 프로세스는 시작부터 세고, 측정 중에 끝난 프로세스는 마지막으로 읽은 때까지 세요.
//
// - CPU 시간(ri_user_time + ri_system_time)은 Apple Silicon에서 mach 시간 단위라 mach_timebase_info로 나노초로 바꿔요.
//   (measure.sh가 측정 앞뒤의 ps TIME도 남겨서 맞는지 대조할 수 있어요)
// - 에너지(ri_energy_nj)는 macOS가 추정한 그 프로세스의 CPU 에너지예요. GPU 몫은 없어서 measure.sh가 powermetrics로 따로 봐요.

import Darwin
import Foundation

// MARK: - 인자

let arguments = CommandLine.arguments
guard arguments.count >= 3, let duration = Double(arguments[1]), duration > 0 else {
    print("사용법: sudo rusage_probe <측정 초> <출력 폴더>")
    exit(2)
}
let outputFolder = URL(fileURLWithPath: arguments[2], isDirectory: true)
let scanInterval: TimeInterval = 2
let appPrefix = "/Applications/MonitorTool.app/"

// MARK: - 역할

enum Role: String, CaseIterable {
    case app, helper, widget, powermetrics, windowServer, chronod

    var label: String {
        switch self {
        case .app: return "앱"
        case .helper: return "보조 프로그램"
        case .widget: return "위젯 확장"
        case .powermetrics: return "powermetrics(보조 프로그램)"
        case .windowServer: return "WindowServer(참고)"
        case .chronod: return "chronod(참고)"
        }
    }

    /// 가족 합계에 넣는지
    var isFamily: Bool {
        switch self {
        case .app, .helper, .widget, .powermetrics: return true
        case .windowServer, .chronod: return false
        }
    }
}

// MARK: - 누적 값

struct Counters {
    var cpuNanoseconds = 0.0
    var instructions = 0.0
    var cycles = 0.0
    var energyNanojoules = 0.0
    var idleWakeups = 0.0
    var interruptWakeups = 0.0
    var diskWriteBytes = 0.0
    var logicalWriteBytes = 0.0

    static func + (lhs: Counters, rhs: Counters) -> Counters {
        Counters(cpuNanoseconds: lhs.cpuNanoseconds + rhs.cpuNanoseconds,
                 instructions: lhs.instructions + rhs.instructions,
                 cycles: lhs.cycles + rhs.cycles,
                 energyNanojoules: lhs.energyNanojoules + rhs.energyNanojoules,
                 idleWakeups: lhs.idleWakeups + rhs.idleWakeups,
                 interruptWakeups: lhs.interruptWakeups + rhs.interruptWakeups,
                 diskWriteBytes: lhs.diskWriteBytes + rhs.diskWriteBytes,
                 logicalWriteBytes: lhs.logicalWriteBytes + rhs.logicalWriteBytes)
    }

    static func - (lhs: Counters, rhs: Counters) -> Counters {
        Counters(cpuNanoseconds: lhs.cpuNanoseconds - rhs.cpuNanoseconds,
                 instructions: lhs.instructions - rhs.instructions,
                 cycles: lhs.cycles - rhs.cycles,
                 energyNanojoules: lhs.energyNanojoules - rhs.energyNanojoules,
                 idleWakeups: lhs.idleWakeups - rhs.idleWakeups,
                 interruptWakeups: lhs.interruptWakeups - rhs.interruptWakeups,
                 diskWriteBytes: lhs.diskWriteBytes - rhs.diskWriteBytes,
                 logicalWriteBytes: lhs.logicalWriteBytes - rhs.logicalWriteBytes)
    }
}

/// 한 번 읽은 값
struct Reading {
    var counters: Counters
    /// 지금 메모리 (바이트)
    var footprintBytes: Double
    /// 프로세스가 뜬 뒤 가장 컸던 메모리 (바이트)
    var maxFootprintBytes: Double
    /// 프로세스가 뜬 시각 (mach 시간). 같은 번호로 다른 프로세스가 떴는지 가려요.
    var startTime: UInt64
}

/// mach 시간 단위 → 나노초 배율 (M1 계열은 125/3)
let timebase: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
}()

func readUsage(_ pid: pid_t) -> Reading? {
    var info = rusage_info_v6()
    // C 함수가 rusage_info_t *로 받지만 실제로는 구조체 주소를 넘겨요.
    let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
        }
    }
    guard result == 0 else { return nil }
    var counters = Counters()
    counters.cpuNanoseconds = (Double(info.ri_user_time) + Double(info.ri_system_time)) * timebase
    counters.instructions = Double(info.ri_instructions)
    counters.cycles = Double(info.ri_cycles)
    counters.energyNanojoules = Double(info.ri_energy_nj)
    counters.idleWakeups = Double(info.ri_pkg_idle_wkups)
    counters.interruptWakeups = Double(info.ri_interrupt_wkups)
    counters.diskWriteBytes = Double(info.ri_diskio_byteswritten)
    counters.logicalWriteBytes = Double(info.ri_logical_writes)
    return Reading(counters: counters,
                   footprintBytes: Double(info.ri_phys_footprint),
                   maxFootprintBytes: Double(info.ri_lifetime_max_phys_footprint),
                   startTime: info.ri_proc_start_abstime)
}

// MARK: - 프로세스 찾기

func allPIDs() -> [pid_t] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
    let count = pids.withUnsafeMutableBytes { raw -> Int32 in
        proc_listallpids(raw.baseAddress, Int32(raw.count))
    }
    guard count > 0 else { return [] }
    return pids.prefix(Int(count)).filter { $0 > 0 }
}

func processName(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 256)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

func executablePath(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

func parentPID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(truncatingIfNeeded: info.pbi_ppid)
}

func classify(pid: pid_t, name: String, helperPIDs: Set<pid_t>) -> Role? {
    switch name {
    case "WindowServer":
        return .windowServer
    case "chronod":
        return .chronod
    case "powermetrics":
        guard let parent = parentPID(pid), helperPIDs.contains(parent) else { return nil }
        return .powermetrics
    default:
        break
    }
    guard name.hasPrefix("MonitorTool"), let path = executablePath(pid) else { return nil }
    // 보조 프로그램은 launchd가 하나만 띄워요. 앱을 다시 설치하면 돌던 보조 프로그램이 예전 앱과 함께
    // 휴지통 경로로 남아 있을 수 있어서(2026-11-04 기준 측정에서 겪음) 경로와 상관없이 세요.
    if path.hasSuffix("/Contents/MacOS/MonitorToolHelper") { return .helper }
    // 앱과 위젯 확장은 설치된 앱만 세요. (Xcode에서 실행한 DerivedData 빌드는 빼요)
    guard path.hasPrefix(appPrefix) else { return nil }
    if path.contains(".appex/") { return .widget }
    if path.hasSuffix("/Contents/MacOS/MonitorTool") { return .app }
    return nil
}

// MARK: - 훑기

struct Tracked {
    let pid: pid_t
    let role: Role
    /// 측정을 시작할 때의 값 (측정 중에 뜬 프로세스는 0)
    let baseline: Counters
    var latest: Reading
    /// 마지막으로 본 차례
    var lastScan: Int
    /// 실행 파일 경로 (보고서에 남겨요)
    let path: String
}

let runStartTime = mach_absolute_time()
let startDate = Date()
var tracked: [pid_t: Tracked] = [:]
var finished: [Tracked] = []
var scanCount = 0
var sampleLines = ["seconds\trole\tpid\tcpu_ms\tinstructions_m\tcycles_m\tenergy_mj\tidle_wakeups\tinterrupt_wakeups\tdisk_write_kb\tfootprint_mb"]

func f(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

func scan() {
    scanCount += 1
    var candidates: [(pid: pid_t, name: String)] = []
    for pid in allPIDs() {
        guard let name = processName(pid) else { continue }
        if name.hasPrefix("MonitorTool") || name == "powermetrics" || name == "WindowServer" || name == "chronod" {
            candidates.append((pid: pid, name: name))
        }
    }
    var helperPIDs = Set<pid_t>()
    for candidate in candidates where candidate.name.hasPrefix("MonitorToolHelpe") {
        if let path = executablePath(candidate.pid), path.hasSuffix("/Contents/MacOS/MonitorToolHelper") {
            helperPIDs.insert(candidate.pid)
        }
    }
    let elapsed = Date().timeIntervalSince(startDate)
    for candidate in candidates {
        guard let role = classify(pid: candidate.pid, name: candidate.name, helperPIDs: helperPIDs),
              let reading = readUsage(candidate.pid) else { continue }
        if var entry = tracked[candidate.pid], entry.latest.startTime == reading.startTime {
            entry.latest = reading
            entry.lastScan = scanCount
            tracked[candidate.pid] = entry
        } else {
            if let old = tracked[candidate.pid] {
                // 같은 번호로 다른 프로세스가 떴어요. 앞의 것은 끝난 것으로 남겨요.
                finished.append(old)
            }
            let startedDuringRun = scanCount > 1 && reading.startTime >= runStartTime
            tracked[candidate.pid] = Tracked(pid: candidate.pid, role: role,
                                             baseline: startedDuringRun ? Counters() : reading.counters,
                                             latest: reading, lastScan: scanCount,
                                             path: executablePath(candidate.pid) ?? "?")
        }
        guard let entry = tracked[candidate.pid] else { continue }
        let delta = entry.latest.counters - entry.baseline
        sampleLines.append([f(elapsed), role.rawValue, String(candidate.pid),
                            f(delta.cpuNanoseconds / 1e6), f(delta.instructions / 1e6), f(delta.cycles / 1e6),
                            f(delta.energyNanojoules / 1e6), f(delta.idleWakeups, 0), f(delta.interruptWakeups, 0),
                            f(delta.diskWriteBytes / 1024), f(reading.footprintBytes / 1_048_576)].joined(separator: "\t"))
    }
}

// MARK: - 측정

scan()
while Date().timeIntervalSince(startDate) < duration {
    let remaining = duration - Date().timeIntervalSince(startDate)
    Thread.sleep(forTimeInterval: max(0.05, min(scanInterval, remaining)))
    scan()
}
let elapsed = Date().timeIntervalSince(startDate)

// MARK: - 합계

struct Total {
    var counters = Counters()
    var pids: [pid_t] = []
    /// 마지막 차례에 살아 있던 프로세스의 메모리 합
    var footprintBytes = 0.0
    /// 가장 컸던 프로세스 하나의 최대 메모리
    var maxFootprintBytes = 0.0
}

var totals: [Role: Total] = [:]
for entry in Array(tracked.values) + finished {
    var total = totals[entry.role] ?? Total()
    total.counters = total.counters + (entry.latest.counters - entry.baseline)
    total.pids.append(entry.pid)
    if entry.lastScan == scanCount {
        total.footprintBytes += entry.latest.footprintBytes
    }
    total.maxFootprintBytes = max(total.maxFootprintBytes, entry.latest.maxFootprintBytes)
    totals[entry.role] = total
}
var family = Total()
for role in Role.allCases where role.isFamily {
    guard let total = totals[role] else { continue }
    family.counters = family.counters + total.counters
    family.pids += total.pids
    family.footprintBytes += total.footprintBytes
}

func cells(_ label: String, _ total: Total, showMax: Bool = true) -> [String] {
    let c = total.counters
    let pidText = total.pids.isEmpty ? "—" : total.pids.sorted().map { String($0) }.joined(separator: ";")
    return [label, pidText,
            f(c.cpuNanoseconds / (elapsed * 1e9) * 100, 3),
            f(c.cpuNanoseconds / 1e9, 2),
            f(c.instructions / elapsed / 1e6, 2),
            f(c.cycles / elapsed / 1e6, 2),
            f(c.energyNanojoules / elapsed / 1e6, 2),
            f(c.idleWakeups / elapsed, 2),
            f(c.interruptWakeups / elapsed, 2),
            f(c.diskWriteBytes / 1024 / (elapsed / 60), 1),
            f(c.logicalWriteBytes / 1024 / (elapsed / 60), 1),
            f(total.footprintBytes / 1_048_576, 1),
            showMax ? f(total.maxFootprintBytes / 1_048_576, 1) : "—"]
}

func row(_ values: [String]) -> String {
    "| " + values.joined(separator: " | ") + " |"
}

let header = ["역할", "PID", "CPU %(한 코어)", "CPU 초", "명령어 M/s", "사이클 M/s", "평균 전력 mW",
              "유휴 깨어남/s", "인터럽트 깨어남/s", "디스크 쓰기 KB/분", "논리 쓰기 KB/분", "메모리 MB(끝)", "최대 MB"]
var report: [String] = []
report.append("측정 \(f(elapsed))초, \(scanCount)번 읽음 (\(f(scanInterval, 0))초 간격), mach 시간 배율 \(f(timebase, 4))")
report.append("")
report.append(row(header))
report.append(row(Array(repeating: "---", count: header.count)))
for role in Role.allCases where role.isFamily {
    report.append(row(cells(role.label, totals[role] ?? Total())))
}
report.append(row(cells("가족 합계", family, showMax: false)))
for role in Role.allCases where !role.isFamily {
    report.append(row(cells(role.label, totals[role] ?? Total())))
}
report.append("")
report.append("프로세스 (역할 · PID · 실행 파일)")
let familyEntries = (Array(tracked.values) + finished).filter { $0.role.isFamily }
for entry in familyEntries.sorted(by: { ($0.role.rawValue, $0.pid) < ($1.role.rawValue, $1.pid) }) {
    let note = entry.path.hasPrefix(appPrefix) || entry.role == .powermetrics ? "" : " ⚠️ 설치된 앱 밖"
    let ended = entry.lastScan == scanCount ? "" : " (측정 중 끝남)"
    report.append("- \(entry.role.label) \(entry.pid): \(entry.path)\(note)\(ended)")
}
let allCounters = totals.values.map({ $0.counters })
if allCounters.map({ $0.instructions }).reduce(0, +) == 0 {
    report.append("")
    report.append("⚠️ 명령어 수가 모두 0이에요. 이 Mac에서는 명령어·사이클을 주지 않는 것 같아요.")
}
if allCounters.map({ $0.energyNanojoules }).reduce(0, +) == 0 {
    report.append("")
    report.append("⚠️ 에너지가 모두 0이에요. 이 Mac에서는 프로세스별 에너지를 주지 않는 것 같아요.")
}
print(report.joined(separator: "\n"))

var table = ["role,pids,cpu_percent,cpu_seconds,instructions_m_per_s,cycles_m_per_s,power_mw,idle_wakeups_per_s,interrupt_wakeups_per_s,disk_write_kb_per_min,logical_write_kb_per_min,footprint_mb_end,footprint_mb_max"]
for role in Role.allCases {
    table.append(cells(role.rawValue, totals[role] ?? Total()).joined(separator: ","))
}
table.append(cells("family", family, showMax: false).joined(separator: ","))

do {
    try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
    try (sampleLines.joined(separator: "\n") + "\n").write(to: outputFolder.appending(path: "samples.tsv"),
                                                            atomically: true, encoding: .utf8)
    try (table.joined(separator: "\n") + "\n").write(to: outputFolder.appending(path: "totals.csv"),
                                                      atomically: true, encoding: .utf8)
} catch {
    print("⚠️ 결과 파일을 쓰지 못함: \(error)")
    exit(1)
}
