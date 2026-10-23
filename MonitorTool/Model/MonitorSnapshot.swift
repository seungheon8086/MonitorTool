import Foundation

/// 한 번 잰 모든 값이에요. 패널(나중에는 위젯도)은 이 값만 보고 화면을 그려요.
nonisolated struct MonitorSnapshot: Hashable, Sendable, Codable {
    /// 마지막으로 값을 모은 시각 (아직 한 번도 못 모았으면 nil)
    var takenAt: Date?
    var cpu = CPUSnapshot()
    var ane = ANESnapshot()
    var gpu = GPUSnapshot()
    var memory = MemorySnapshot()
    var thermal = ThermalSnapshot()
    var battery = BatterySnapshot()
    var network = NetworkSnapshot()
    /// CPU·ANE 전력을 읽는 관리자 권한 보조 프로그램의 상태
    var helper: HelperStatus = .unknown
}

// MARK: - CPU

nonisolated struct CPUSnapshot: Hashable, Sendable, Codable {
    /// E 코어 묶음의 평균 사용률 (0–100 %)
    var efficiencyUsage: Reading<Double> = .preparing
    /// P 코어 묶음의 평균 사용률 (0–100 %)
    var performanceUsage: Reading<Double> = .preparing
    /// CPU 전체 전력 (W)
    var power: Reading<Double> = .preparing
    /// 코어별 사용률
    var cores: [CoreUsage] = []
}

nonisolated struct CoreUsage: Hashable, Sendable, Codable, Identifiable {
    /// CPU 번호 (0부터)
    var id: Int
    var kind: CoreKind
    /// 묶음(클러스터) 번호
    var cluster: Int
    /// 사용률 (0–100 %)
    var usage: Double
}

nonisolated enum CoreKind: String, Hashable, Sendable, Codable {
    /// E 코어 (효율)
    case efficiency
    /// P 코어 (성능)
    case performance
}

/// 같은 묶음(클러스터)에 속한 코어들이에요. 상세 화면에서 묶음별로 보여줘요.
nonisolated struct CoreGroup: Hashable, Sendable, Identifiable {
    var kind: CoreKind
    var cluster: Int
    var title: String
    var cores: [CoreUsage]

    var id: String { "\(kind.rawValue)-\(cluster)" }
}

extension CPUSnapshot {
    /// 코어를 묶음별로 나눠요. 이름은 'E', 'P 묶음 1', 'P 묶음 2'처럼 붙여요.
    nonisolated var coreGroups: [CoreGroup] {
        var groups: [CoreGroup] = []
        for core in cores {
            if let index = groups.firstIndex(where: { $0.kind == core.kind && $0.cluster == core.cluster }) {
                groups[index].cores.append(core)
            } else {
                groups.append(CoreGroup(kind: core.kind, cluster: core.cluster, title: "", cores: [core]))
            }
        }

        let efficiencyCount = groups.filter { $0.kind == .efficiency }.count
        let performanceCount = groups.filter { $0.kind == .performance }.count
        var efficiencyNumber = 0
        var performanceNumber = 0
        for index in groups.indices {
            switch groups[index].kind {
            case .efficiency:
                efficiencyNumber += 1
                groups[index].title = efficiencyCount > 1 ? "E 묶음 \(efficiencyNumber)" : "E"
            case .performance:
                performanceNumber += 1
                groups[index].title = performanceCount > 1 ? "P 묶음 \(performanceNumber)" : "P"
            }
        }
        return groups
    }
}

// MARK: - ANE

nonisolated struct ANESnapshot: Hashable, Sendable, Codable {
    /// 사용 중인지 (ANE 전원 상태로 판단해요)
    var isActive: Reading<Bool> = .preparing
    /// 이번에 켜진 시각
    var activeSince: Date?
    /// ANE 전력 (W)
    var power: Reading<Double> = .preparing
    /// 사용률은 macOS가 알려 주지 않아서 늘 '측정 불가'예요.
    var usage: Reading<Double> = .notMeasurable(ANESnapshot.usageReason)
    /// ANE가 DRAM과 주고받은 양 (바이트/초)
    var dramTraffic: Reading<Double> = .preparing
    /// ANE 온도 (°C). ANE가 쉬는 동안은 '꺼짐'이에요.
    var temperature: Reading<Double> = .preparing

    static let usageReason = "macOS가 ANE가 일한 시간의 비율을 알려 주지 않아요."
}

// MARK: - GPU

nonisolated struct GPUSnapshot: Hashable, Sendable, Codable {
    /// GPU 사용률 (Device Utilization, 0–100 %)
    var usage: Reading<Double> = .preparing
    /// GPU 전력 (W)
    var power: Reading<Double> = .preparing
}

// MARK: - 메모리

nonisolated struct MemorySnapshot: Hashable, Sendable, Codable {
    /// 쓰는 메모리 (바이트)
    var used: Reading<Double> = .preparing
    /// 전체 메모리 (바이트)
    var total: Reading<Double> = .preparing
    var pressure: Reading<MemoryPressure> = .preparing
    /// 압축된 메모리 (바이트)
    var compressed: Reading<Double> = .preparing
    /// 쓰고 있는 스왑 (바이트)
    var swapUsed: Reading<Double> = .preparing
    /// DRAM 트래픽 합계 (바이트/초). 칩 안 캐시에서 끝난 요청은 빼요.
    var trafficTotal: Reading<Double> = .preparing
    var trafficRead: Reading<Double> = .preparing
    var trafficWrite: Reading<Double> = .preparing
    /// 기기별 DRAM 트래픽 (바이트/초)
    var trafficByDevice: [DeviceTraffic] = []
}

nonisolated enum MemoryPressure: String, Hashable, Sendable, Codable {
    case normal
    case warning
    case critical
}

nonisolated enum TrafficDevice: String, Hashable, Sendable, Codable, CaseIterable {
    case cpu, gpu, ane, display, storage, other
}

nonisolated struct DeviceTraffic: Hashable, Sendable, Codable, Identifiable {
    var device: TrafficDevice
    /// 바이트/초
    var bytesPerSecond: Double

    var id: TrafficDevice { device }
}

extension MemorySnapshot {
    /// 사용률 (%) — 쓰는 양과 전체 양을 모두 읽었을 때만 계산해요.
    nonisolated var usagePercent: Reading<Double> {
        guard let usedBytes = used.okValue, let totalBytes = total.okValue, totalBytes > 0 else {
            let state = used.state == .ok ? total.state : used.state
            return Reading(value: nil, state: state, measuredAt: nil)
        }
        return .ok(usedBytes / totalBytes * 100, at: used.measuredAt ?? Date())
    }

    /// 한 기기의 DRAM 트래픽 (바이트/초). 아직 없으면 nil이에요.
    nonisolated func traffic(of device: TrafficDevice) -> Double? {
        trafficByDevice.first { $0.device == device }?.bytesPerSecond
    }
}

// MARK: - 온도·팬

nonisolated struct ThermalSnapshot: Hashable, Sendable, Codable {
    /// CPU 코어 센서 중 최고 (°C)
    var cpuMax: Reading<Double> = .preparing
    /// GPU 센서 중 최고 (°C)
    var gpuMax: Reading<Double> = .preparing
    /// 배터리 온도 (°C)
    var battery: Reading<Double> = .preparing
    /// SSD 온도 (°C)
    var ssd: Reading<Double> = .preparing
    /// 팬 목록. 팬이 없는 Mac이면 '미지원'이에요.
    var fans: Reading<[FanReading]> = .preparing
}

nonisolated struct FanReading: Hashable, Sendable, Codable, Identifiable {
    /// 팬 번호 (0부터). 화면에는 1부터 보여줘요.
    var id: Int
    /// 실제 회전수 (RPM). 읽기에 성공한 0은 '정지'예요.
    var rpm: Reading<Double>
    var minimumRPM: Double?
    var maximumRPM: Double?
    var mode: FanMode
}

nonisolated enum FanMode: String, Hashable, Sendable, Codable {
    /// 시스템이 알아서 조절해요.
    case automatic
    /// 수동으로 정한 회전수예요.
    case manual
    case unknown
}

// MARK: - 배터리

nonisolated struct BatterySnapshot: Hashable, Sendable, Codable {
    /// 잔량 (0–100 %)
    var level: Reading<Double> = .preparing
    /// 충전 중·방전 중·완충·충전 보류
    var chargeState: Reading<BatteryState> = .preparing
    /// 배터리로 들어가는(+)·나오는(−) 순전력 (W)
    var netPower: Reading<Double> = .preparing
    /// macOS가 추정한 시간 (초). 방전 중이면 남은 시간, 충전 중이면 완충까지 걸리는 시간이에요.
    var timeRemaining: Reading<Double> = .preparing
    /// 성능 상태 (예: 정상)
    var condition: Reading<String> = .preparing
    /// 최대 용량 (새 배터리 대비 %)
    var maximumCapacity: Reading<Double> = .preparing
    var cycleCount: Reading<Int> = .preparing
}

nonisolated enum BatteryState: String, Hashable, Sendable, Codable {
    /// 충전 중
    case charging
    /// 방전 중
    case discharging
    /// 완충
    case charged
    /// 전원이 연결됐지만 충전하지 않아요 (충전 보류)
    case onHold
}

// MARK: - 네트워크

nonisolated struct NetworkSnapshot: Hashable, Sendable, Codable {
    /// 받는 속도 (바이트/초)
    var download: Reading<Double> = .preparing
    /// 보내는 속도 (바이트/초)
    var upload: Reading<Double> = .preparing
    /// 오늘 받은 양 (바이트)
    var todayDownloaded: Reading<Double> = .preparing
    /// 오늘 보낸 양 (바이트)
    var todayUploaded: Reading<Double> = .preparing
    /// '오늘'의 기준 날짜
    var todayDate: Date?
    /// 이번 실행 동안 받은 양 (바이트)
    var sessionDownloaded: Reading<Double> = .preparing
    /// 이번 실행 동안 보낸 양 (바이트)
    var sessionUploaded: Reading<Double> = .preparing
    var sessionStartedAt: Date?
    /// 인터페이스별 속도
    var interfaces: [InterfaceRate] = []
}

nonisolated struct InterfaceRate: Hashable, Sendable, Codable, Identifiable {
    /// BSD 이름 (예: en0)
    var id: String
    /// 보여줄 이름 (예: Wi-Fi)
    var displayName: String
    /// 받는 속도 (바이트/초)
    var download: Double
    /// 보내는 속도 (바이트/초)
    var upload: Double
}

// MARK: - 보조 프로그램

nonisolated enum HelperStatus: String, Hashable, Sendable, Codable {
    /// 아직 확인하지 않았어요. 보조 프로그램은 5단계(통합)에서 붙여요.
    case unknown
    /// 등록하지 않았어요.
    case notRegistered
    /// 시스템 설정에서 허용해야 해요.
    case requiresApproval
    /// 허용돼서 동작 중이에요.
    case enabled

    /// 패널 아래에 '허용하기' 버튼을 보여줘야 하는지
    var needsUserAction: Bool {
        self == .notRegistered || self == .requiresApproval
    }
}
