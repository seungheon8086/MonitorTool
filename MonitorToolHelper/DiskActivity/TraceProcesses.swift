// 디스크 활성 시간: 비켜줄 추적 도구와 프로세스 보기. (docs/DISK_ACTIVE_TIME.md 3.3)
// Diagnostics/DiskActiveProbe/Sources/Stage3.swift에서 옮겼다. 프로세스 이름은 도구처럼 ps를 띄우지 않고 sysctl로 읽는다.
import Darwin

/// 비켜줄 추적 도구 (프로세스 이름, p_comm 16자 안).
/// spindump는 늘 떠 있는 시스템 데몬이라 넣지 않는다 (도구 3단계 첫 시험: 내내 있었고 추적과 부딪히지 않음)
let traceToolNames: Set<String> = ["fs_usage", "sc_usage", "latency", "ktrace", "xctrace", "Instruments", "sysdiagnose"]

/// 프로세스가 아직 있는지 (root라 권한 문제는 없다)
func processAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

private func commandName(_ proc: kinfo_proc) -> String {
    var comm = proc.kp_proc.p_comm
    return withUnsafeBytes(of: &comm) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

/// 지금 도는 프로세스 중 이름이 names에 든 것 (나는 빼고). sysctl KERN_PROC_ALL 한 번 (약 2 ms라 잡기 직전에만)
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
        let name = commandName(procs[i])
        if names.contains(name) { out.append((pid: pid, name: name)) }
    }
    return out
}

/// 프로세스 이름 (sysctl KERN_PROC_PID). 끝난 프로세스면 nil
func processName(_ pid: Int32) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var proc = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = commandName(proc)
    return name.isEmpty ? nil : name
}
