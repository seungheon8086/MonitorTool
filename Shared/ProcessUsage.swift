import Darwin
import Dispatch
import Foundation

/// 이 프로세스가 쓴 CPU 시간과 메모리를 10분마다 기록에 한 줄 남겨요. 앱과 보조 프로그램이 각자 자기 것을 남겨요.
/// 실사용 점검용: 오래 켜 두면 메모리가 늘어나는지, 평소 CPU를 얼마나 쓰는지 (2026-11-21)
/// - CPU %: 지난 줄부터 깨어 있던 시간(잠든 시간 빼고) 동안의 평균, 한 코어 기준 (활성 상태 보기의 CPU %와 같은 뜻)
/// - 메모리: phys_footprint (활성 상태 보기의 '메모리'와 같은 값)
/// 상태는 전용 큐에서만 만져요.
nonisolated final class UsageReporter: @unchecked Sendable {
    /// 간격 (초). 깨어 있는 시간 기준이에요. (잠든 동안은 타이머가 멈춰요)
    private static let interval = 600
    private let queue = DispatchQueue(label: "com.seungheon.MonitorTool.usage", qos: .utility)
    private let report: @Sendable (String) -> Void
    private var timer: (any DispatchSourceTimer)?
    private var lastCPU: Double = 0
    private var lastAwake: UInt64 = 0

    init(report: @escaping @Sendable (String) -> Void) {
        self.report = report
    }

    func start() {
        queue.async {
            self.startTimer()
        }
    }

    /// queue 안에서만 불러요.
    private func startTimer() {
        guard timer == nil else { return }
        lastCPU = UsageReporter.cpuSeconds()
        lastAwake = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(UsageReporter.interval),
                        repeating: .seconds(UsageReporter.interval), leeway: .seconds(60))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
    }

    private func tick() {
        let cpu = UsageReporter.cpuSeconds()
        let awake = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var parts: [String] = []
        if awake > lastAwake {
            let seconds = Double(awake - lastAwake) / 1e9
            let percent = (cpu - lastCPU) / seconds * 100
            parts.append(String(format: "CPU %.2f%% (깨어 있던 %.1f분, 한 코어 기준)", percent, seconds / 60))
        }
        parts.append(String(format: "누적 CPU %.1f초", cpu))
        if let footprint = UsageReporter.memoryFootprint() {
            parts.append(String(format: "메모리 %.1f MB", Double(footprint) / 1_048_576))
        } else {
            parts.append("메모리 읽기 실패")
        }
        lastCPU = cpu
        lastAwake = awake
        report("자원 · " + parts.joined(separator: " · "))
    }

    /// 이 프로세스가 쓴 CPU 시간 (초, 사용자 + 시스템)
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    /// 이 프로세스의 메모리 (활성 상태 보기의 '메모리'와 같은 phys_footprint, 바이트)
    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }
}

/// 실행 파일의 수정 시각(빌드한 때)이에요. 켜질 때 기록에 남겨서 새 빌드인지 가려 봐요.
nonisolated enum ExecutableStamp {
    static var text: String {
        guard let path = Bundle.main.executableURL?.path(percentEncoded: false),
              let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            return "알 수 없음"
        }
        return date.formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }
}
