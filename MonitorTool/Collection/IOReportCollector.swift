import Darwin
import Foundation

/// 메모리 컨트롤러의 바이트 카운터(AMC Stats / Perf Counters)에서 DRAM 단(DCS) 값만 모아요.
/// 'DCS'가 붙지 않은 값은 칩 안 캐시에서 끝난 요청까지 들어 있어서 쓰지 않아요. (설계 문서 3장)
nonisolated struct DRAMTrafficCounter {
    /// 전체 읽기 (바이트, 'DCS RD')
    var totalRead: Int64?
    /// 전체 쓰기 (바이트, 'DCS WR')
    var totalWrite: Int64?
    /// 기기 묶음별 읽기+쓰기 (바이트, '<기기> DCS RD'·'<기기> DCS WR')
    var byDevice: [TrafficDevice: Int64] = [:]
    /// 거꾸로 줄어든 카운터가 있었는지 (카운터가 처음부터 다시 셌을 때)
    var hasNegative = false

    /// 채널 하나를 더해요. 전체·기기별 'DCS RD'·'DCS WR'이 아닌 채널은 건너뛰어요.
    mutating func add(channel name: String, bytes: Int64) {
        if bytes < 0 {
            hasNegative = true
        }
        switch name {
        case "DCS RD":
            totalRead = (totalRead ?? 0) + bytes
        case "DCS WR":
            totalWrite = (totalWrite ?? 0) + bytes
        default:
            guard name.hasSuffix(" DCS RD") || name.hasSuffix(" DCS WR") else {
                return
            }
            let deviceName = String(name.dropLast(" DCS RD".count))
            byDevice[DRAMTrafficCounter.device(named: deviceName), default: 0] += bytes
        }
    }

    /// 기기 이름(채널 이름의 앞부분)을 화면의 기기 묶음으로 나눠요.
    /// CPU는 P코어 묶음(PCPU0·PCPU1)과 E코어 묶음(ECPU), 화면은 내장(DISP)과 외장(EXT DISP0·1)이에요.
    static func device(named name: String) -> TrafficDevice {
        if name.hasPrefix("PCPU") || name.hasPrefix("ECPU") || name.hasPrefix("CPU") {
            return .cpu
        }
        if name.hasPrefix("GFX") {
            return .gpu
        }
        if name.hasPrefix("ANE") {
            return .ane
        }
        if name.hasPrefix("DISP") || name.hasPrefix("EXT DISP") {
            return .display
        }
        if name.hasPrefix("ANS") {
            return .storage
        }
        return .other
    }
}

/// IOReport로 GPU 전력, ANE 사용 중 여부, DRAM 트래픽(합계·읽기·쓰기·기기별·ANE)을 재요. 관리자 권한이 없어도 돼요.
/// (설계 문서 3장, Diagnostics/PowerProbe 2·3차와 메모리 트래픽 추가 분석)
final class IOReportCollector {
    private let library: IOReportLibrary?
    /// Energy Model: 이 중 'GPU Energy'만 권한 없이 갱신돼요. (CPU·ANE 전력은 보조 프로그램이 재요)
    private let energy: IOReportSubscription?
    /// SoC Stats / Cluster Power States: ANE의 전원 상태(INACT·ACT) 시간
    private let clusterPower: IOReportSubscription?
    /// AMC Stats / Perf Counters: 메모리 컨트롤러의 바이트 카운터
    private let memoryCounters: IOReportSubscription?
    /// 마지막으로 잰 때 (깨어 있던 시간만 세는 시계, 나노초). 잠든 동안은 카운터도 거의 늘지 않아요.
    private var lastMeasuredAt: UInt64
    /// ANE가 이번에 켜진 것을 처음 본 시각
    private var aneActiveSince: Date?

    /// 앞 표본과 이보다 가까우면 새로 재지 않아요. 구간이 짧으면 값이 튀어요. (나노초)
    private static let minimumInterval: UInt64 = 500_000_000
    /// 새로 잴 때마다 그래프에 남기는 계열
    private static let metrics: [Metric] = [.gpuPower, .aneTraffic,
                                            .traffic(.cpu), .traffic(.gpu), .traffic(.ane), .traffic(.other)]

    init() {
        let library = IOReportLibrary()
        self.library = library
        // 구독할 때 첫 표본을 기준으로 잡아요. 첫 값은 다음 표본(0.5초 이상 뒤)에 나와요.
        energy = library.flatMap { IOReportSubscription(library: $0, group: "Energy Model") }
        clusterPower = library.flatMap { IOReportSubscription(library: $0, group: "SoC Stats", subgroup: "Cluster Power States") }
        memoryCounters = library.flatMap { IOReportSubscription(library: $0, group: "AMC Stats", subgroup: "Perf Counters") }
        lastMeasuredAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// GPU 전력, ANE 사용 중 여부, DRAM 트래픽을 채우고, 그래프에 남길 계열을 돌려줘요.
    /// 바로 앞에 쟀으면(0.5초 안) 빈 목록을 돌려주고 스냅숏은 그대로예요.
    func update(_ snapshot: inout MonitorSnapshot, now: Date) -> [Metric] {
        let awake = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = awake &- lastMeasuredAt
        guard elapsed >= IOReportCollector.minimumInterval else {
            return []
        }
        lastMeasuredAt = awake
        let seconds = Double(elapsed) / 1_000_000_000
        snapshot.gpu.power = gpuPower(over: seconds, at: now)
        updateANEActivity(&snapshot.ane, at: now)
        updateTraffic(&snapshot, over: seconds, at: now)
        return IOReportCollector.metrics
    }

    // MARK: - GPU 전력

    /// 구간 동안 늘어난 GPU 에너지 ÷ 구간 길이 (W)
    private func gpuPower(over seconds: Double, at date: Date) -> Reading<Double> {
        guard let library, let energy, let channels = energy.delta() else {
            return .failed("GPU 에너지 카운터를 읽지 못했어요.")
        }
        guard let channel = channels.first(where: { library.name(of: $0) == "GPU Energy" }) else {
            return .failed("GPU 에너지 값을 찾지 못했어요.")
        }
        guard let joulesPerUnit = IOReportLibrary.joulesPerUnit(library.unit(of: channel)) else {
            return .failed("GPU 에너지의 단위를 알 수 없어요.")
        }
        let energyValue = library.simpleValue(channel, 0)
        guard energyValue >= 0 else {
            // 카운터가 처음부터 다시 셌어요. 다음 표본부터 다시 계산해요.
            return .preparing
        }
        return .ok(Double(energyValue) * joulesPerUnit / seconds, at: date)
    }

    // MARK: - ANE 사용 중

    /// 구간 안에서 ANE 전원이 한 번이라도 켜져 있었으면 '사용 중'이에요.
    /// 켜져 있던 시간 비율은 일한 양에 비례하지 않아서 %로 쓰지 않아요. (설계 문서 3장, PowerProbe 3차)
    private func updateANEActivity(_ ane: inout ANESnapshot, at date: Date) {
        guard let library, let clusterPower, let channels = clusterPower.delta() else {
            aneActiveSince = nil
            ane.isActive = .failed("ANE 전원 상태를 읽지 못했어요.")
            ane.activeSince = nil
            return
        }
        // M1 Pro에는 ANE0 하나예요. ANE가 둘인 Mac(ANE0·ANE1)은 하나라도 켜져 있으면 사용 중이에요.
        let aneChannels = channels.filter { library.name(of: $0).hasPrefix("ANE") }
        guard !aneChannels.isEmpty else {
            aneActiveSince = nil
            ane.isActive = .failed("ANE 전원 상태를 찾지 못했어요.")
            ane.activeSince = nil
            return
        }
        let isActive = aneChannels.contains { library.activeResidency(of: $0) > 0 }
        if isActive {
            if aneActiveSince == nil {
                aneActiveSince = date
            }
        } else {
            aneActiveSince = nil
        }
        ane.isActive = .ok(isActive, at: date)
        ane.activeSince = aneActiveSince
    }

    // MARK: - DRAM 트래픽

    /// 메모리 항목의 DRAM 트래픽(합계·읽기·쓰기·기기별)과 ANE 상세의 ANE DRAM 트래픽을 채워요. (바이트/초)
    private func updateTraffic(_ snapshot: inout MonitorSnapshot, over seconds: Double, at date: Date) {
        guard let library, let memoryCounters, let channels = memoryCounters.delta() else {
            setTraffic(&snapshot, .failed("메모리 컨트롤러 카운터를 읽지 못했어요."))
            return
        }
        var counter = DRAMTrafficCounter()
        for channel in channels {
            counter.add(channel: library.name(of: channel), bytes: library.simpleValue(channel, 0))
        }
        guard !counter.hasNegative else {
            // 카운터가 처음부터 다시 셌어요. 다음 표본부터 다시 계산해요.
            setTraffic(&snapshot, .preparing)
            return
        }
        guard let read = counter.totalRead, let write = counter.totalWrite else {
            setTraffic(&snapshot, .failed("DRAM 트래픽 합계를 찾지 못했어요."))
            return
        }
        snapshot.memory.trafficRead = .ok(Double(read) / seconds, at: date)
        snapshot.memory.trafficWrite = .ok(Double(write) / seconds, at: date)
        snapshot.memory.trafficTotal = .ok(Double(read + write) / seconds, at: date)
        snapshot.memory.trafficByDevice = TrafficDevice.allCases.compactMap { (device: TrafficDevice) -> DeviceTraffic? in
            guard let bytes = counter.byDevice[device] else {
                return nil
            }
            return DeviceTraffic(device: device, bytesPerSecond: Double(bytes) / seconds)
        }
        if let aneBytes = counter.byDevice[.ane] {
            snapshot.ane.dramTraffic = .ok(Double(aneBytes) / seconds, at: date)
        } else {
            snapshot.ane.dramTraffic = .failed("ANE의 DRAM 값을 찾지 못했어요.")
        }
    }

    /// 트래픽 값을 모두 같은 상태로 둬요. (읽지 못했거나 다음 표본을 기다릴 때)
    private func setTraffic(_ snapshot: inout MonitorSnapshot, _ reading: Reading<Double>) {
        snapshot.memory.trafficTotal = reading
        snapshot.memory.trafficRead = reading
        snapshot.memory.trafficWrite = reading
        snapshot.memory.trafficByDevice = []
        snapshot.ane.dramTraffic = reading
    }
}
