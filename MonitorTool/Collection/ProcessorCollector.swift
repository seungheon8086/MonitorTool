import Darwin
import Foundation
import IOKit

/// CPU 하나가 어느 묶음(클러스터)에 속하는지예요. (IODeviceTree의 cpus 아래 항목)
nonisolated struct CoreLayout: Hashable, Sendable {
    /// CPU 번호. host_processor_info의 순서와 같아요. (logical-cpu-id)
    var id: Int
    var kind: CoreKind
    /// 묶음 번호 (cluster-id)
    var cluster: Int
}

/// CPU 번호와 E/P 묶음의 대응을 읽어요. 코어 순서를 가정하지 않고 기기가 알려 주는 값을 써요.
/// (설계 문서 3장, Diagnostics/PowerProbe 3차: CPU 0·1은 E, 2~5는 P 묶음 1, 6~9는 P 묶음 2)
/// 속성마다 값의 종류가 달라요. macOS 27에서 logical-cpu-id는 숫자, cluster-type·cluster-id는 바이트였어요.
/// 그래서 숫자와 바이트를 모두 받아요. (2026-10-25 확인)
nonisolated enum CoreLayoutReader {
    /// 읽지 못하면 빈 목록이에요.
    static func read() -> [CoreLayout] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else {
            return []
        }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var layouts: [CoreLayout] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let id = integer(entry, "logical-cpu-id"),
               let type = text(entry, "cluster-type"),
               let kind = coreKind(type) {
                layouts.append(CoreLayout(id: id, kind: kind, cluster: integer(entry, "cluster-id") ?? 0))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return layouts.sorted { $0.id < $1.id }
    }

    private static func coreKind(_ type: String) -> CoreKind? {
        switch type {
        case "E":
            return .efficiency
        case "P":
            return .performance
        default:
            return nil
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// 정수 속성. 디바이스 트리는 보통 리틀 엔디언 바이트로 주지만, 숫자로 줘도 받아요.
    private static func integer(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        guard let value = property(entry, key) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        guard let data = value as? Data, (1...8).contains(data.count) else {
            return nil
        }
        var number: UInt64 = 0
        for (offset, byte) in data.enumerated() {
            number |= UInt64(byte) << (8 * UInt64(offset))
        }
        return Int(truncatingIfNeeded: number)
    }

    /// 글자 속성. 바이트(끝의 0은 떼요)로 줘도, 글자로 줘도 받아요.
    private static func text(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = property(entry, key) else {
            return nil
        }
        let string: String
        if let data = value as? Data {
            string = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        } else if let plain = value as? String {
            string = plain
        } else {
            return nil
        }
        return string.isEmpty ? nil : string
    }
}

/// CPU 하나의 누적 틱이에요. (host_processor_info) 32비트라 아주 오래 켜 두면 0으로 돌아가요.
nonisolated struct CPUTicks: Hashable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// CPU별 누적 틱을 읽어요.
nonisolated enum CPUTicksReader {
    /// mach_host_self()는 부를 때마다 포트 참조가 늘어서 한 번만 받아 둬요.
    private static let host = mach_host_self()

    /// CPU 번호 순서의 누적 틱. 읽지 못하면 nil이에요.
    static func read() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var infoPointer: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoPointer, &infoCount) == KERN_SUCCESS,
              let info = infoPointer else {
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { (cpu: Int) -> CPUTicks in
            let base = cpu * Int(CPU_STATE_MAX)
            return CPUTicks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                            system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                            nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
    }
}

/// 두 번 읽은 틱의 차이로 CPU별 사용률을 계산해요. (OS가 집계한 CPU 시간 비율, 설계 문서 3장)
nonisolated struct CPUUsageMeter {
    private var previous: [CPUTicks] = []

    /// CPU별 사용률 (0–100 %). 첫 표본이거나 CPU 수가 바뀌었으면 nil이에요.
    mutating func add(_ ticks: [CPUTicks]) -> [Double]? {
        defer { previous = ticks }
        guard previous.count == ticks.count, !ticks.isEmpty else {
            return nil
        }
        var usages: [Double] = []
        for (old, new) in zip(previous, ticks) {
            // 32비트 카운터라 0으로 돌아가도 &-로 바로 차이를 구할 수 있어요.
            let busy = Double(new.user &- old.user) + Double(new.system &- old.system) + Double(new.nice &- old.nice)
            let total = busy + Double(new.idle &- old.idle)
            // 두 표본 사이에 틱이 하나도 쌓이지 않은 CPU는 일한 틱(busy)도 0이에요.
            // 지어낸 0이 아니라 잰 0이라서 0 %로 봐요. (한 CPU 때문에 전체를 비우지 않아요)
            usages.append(total > 0 ? min(max(busy / total * 100, 0), 100) : 0)
        }
        return usages
    }
}

/// CPU 사용률(코어별, E·P 묶음별)과 GPU 사용률을 재요.
/// E/P는 OS가 집계한 CPU 시간의 묶음별 평균, GPU는 IORegistry의 'Device Utilization %'예요. (설계 문서 1·3장)
final class ProcessorCollector {
    private let layouts: [CoreLayout]
    private var usageMeter = CPUUsageMeter()
    /// 처음 찾은 GPU(IOAccelerator). 매번 찾지 않고 기억해 둬요.
    private var gpuService: io_object_t = 0
    /// 마지막으로 잰 때 (깨어 있던 시간만 세는 시계, 나노초)
    private var lastMeasuredAt: UInt64 = 0

    /// 앞 표본과 이보다 가까우면 새로 재지 않아요. 틱이 몇 개 안 쌓여서 값이 튀어요. (나노초)
    private static let minimumInterval: UInt64 = 500_000_000

    init() {
        layouts = CoreLayoutReader.read()
    }

    /// 스냅숏의 CPU 사용률·코어별 값과 GPU 사용률을 채워요. (전력은 다른 곳에서 넣어요)
    /// 새로 쟀으면 true예요. 바로 앞에 재서 건너뛰었으면 false이고 스냅숏은 그대로예요.
    func update(_ snapshot: inout MonitorSnapshot, now: Date) -> Bool {
        let awake = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if lastMeasuredAt != 0, awake &- lastMeasuredAt < ProcessorCollector.minimumInterval {
            return false
        }
        lastMeasuredAt = awake
        updateCPU(&snapshot.cpu, now: now)
        snapshot.gpu.usage = readGPUUsage(at: now)
        return true
    }

    // MARK: - CPU

    private func updateCPU(_ cpu: inout CPUSnapshot, now: Date) {
        guard let ticks = CPUTicksReader.read() else {
            setCPUState(&cpu, .failed("CPU 사용 시간을 읽지 못했어요."))
            return
        }
        guard let usages = usageMeter.add(ticks) else {
            // 첫 표본은 기준점이에요. 다음 표본부터 사용률을 알 수 있어요.
            setCPUState(&cpu, .preparing)
            return
        }
        guard !layouts.isEmpty else {
            setCPUState(&cpu, .failed("CPU 묶음(E·P)을 읽지 못했어요."))
            return
        }
        let cores = layouts.compactMap { (layout: CoreLayout) -> CoreUsage? in
            guard usages.indices.contains(layout.id) else { return nil }
            return CoreUsage(id: layout.id, kind: layout.kind, cluster: layout.cluster, usage: usages[layout.id])
        }
        cpu.cores = cores
        cpu.efficiencyUsage = average(of: .efficiency, in: cores, at: now)
        cpu.performanceUsage = average(of: .performance, in: cores, at: now)
    }

    /// 묶음 안 코어들의 평균. 그 종류의 코어가 없는 Mac이면 '미지원'이에요.
    private func average(of kind: CoreKind, in cores: [CoreUsage], at date: Date) -> Reading<Double> {
        let values = cores.filter { $0.kind == kind }.map(\.usage)
        guard !values.isEmpty else {
            return .unsupported
        }
        return .ok(values.reduce(0, +) / Double(values.count), at: date)
    }

    private func setCPUState(_ cpu: inout CPUSnapshot, _ reading: Reading<Double>) {
        cpu.efficiencyUsage = reading
        cpu.performanceUsage = reading
        cpu.cores = []
    }

    // MARK: - GPU

    /// GPU 사용률 (0–100 %)
    private func readGPUUsage(at date: Date) -> Reading<Double> {
        if gpuService == 0 {
            gpuService = ProcessorCollector.findGPUService()
            guard gpuService != 0 else {
                return .failed("사용률을 알려 주는 GPU를 찾지 못했어요.")
            }
        }
        guard let value = ProcessorCollector.deviceUtilization(of: gpuService) else {
            // GPU가 바뀌었거나 사라졌을 수 있어요. 다음에 다시 찾아요.
            IOObjectRelease(gpuService)
            gpuService = 0
            return .failed("GPU 사용률을 읽지 못했어요.")
        }
        return .ok(min(max(value, 0), 100), at: date)
    }

    /// 'Device Utilization %'를 알려 주는 첫 GPU를 찾아요. 찾은 서비스는 부른 쪽이 갖고 있다가 놓아요.
    private static func findGPUService() -> io_object_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if deviceUtilization(of: service) != nil {
                return service
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return 0
    }

    private static func deviceUtilization(of service: io_object_t) -> Double? {
        guard let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let value = statistics["Device Utilization %"] as? NSNumber else {
            return nil
        }
        return value.doubleValue
    }
}
