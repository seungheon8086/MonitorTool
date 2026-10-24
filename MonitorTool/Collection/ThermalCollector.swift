import Foundation

/// 센서 묶음 하나를 읽은 결과예요.
nonisolated enum SensorGroupReading: Hashable, Sendable {
    /// 쓸 수 있는 값 중 가장 높은 온도 (°C)
    case highest(Double)
    /// 읽었지만 모든 센서가 꺼져 있었어요. (0 °C나 멈춘 낮은 값을 주는 센서)
    case off
    /// 하나도 읽지 못했어요.
    case unreadable

    /// 읽은 값들에서 묶음의 결과를 정해요. minimum 이하는 꺼진 센서로 봐요. (0 °C로 보여주지 않아요)
    static func from(_ values: [Double?], minimum: Double) -> SensorGroupReading {
        let read = values.compactMap { $0 }
        guard !read.isEmpty else {
            return .unreadable
        }
        guard let highest = read.filter({ $0.isFinite && $0 > minimum }).max() else {
            return .off
        }
        return .highest(highest)
    }
}

/// 온도와 팬을 재요. 모두 관리자 권한 없이 SMC에서 읽어요. (설계 문서 3장, Diagnostics/SensorProbe)
final class ThermalCollector {
    /// CPU 영역: P코어 센서 8개와 E코어 센서 2개. 부하 실험에서 CPU 부하에 가장 크게 반응했어요.
    /// (이름이 이웃한 짝 키는 같은 센서를 약 9 °C 낮게 보정한 값이라 빼고, 높은 쪽을 써요)
    private static let cpuKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b"]
    /// GPU 영역: GPU 부하에서 가장 높았던 센서 2개
    private static let gpuKeys = ["Tg05", "Tg0D"]
    /// ANE: ANE가 켜져 있을 때만 값이 있어요. 꺼지면 0이거나 멈춘 낮은 값(8~11 °C)이에요.
    private static let aneKeys = ["Ta00", "Ta01", "Ta02", "Ta04", "Ta05", "Ta06"]
    /// 배터리 센서 3개 (32 °C 안팎)
    private static let batteryKeys = ["TB0T", "TB1T", "TB2T"]
    /// SSD: 진단 때 HID 'NAND CH0 temp'와 같이 움직였어요(1 °C 안쪽). TH0x는 TH0a·TH0b 중 높은 값이에요.
    private static let ssdKeys = ["TH0x"]
    /// ANE 센서가 이보다 낮으면 꺼진 것으로 봐요. (멈춘 낮은 값을 거르려고요)
    private static let aneMinimum = 20.0

    private let smc: SMC?
    /// 이 Mac에 있는 키만 남긴 묶음들
    private let cpuKeys: [String]
    private let gpuKeys: [String]
    private let aneKeys: [String]
    private let batteryKeys: [String]
    private let ssdKeys: [String]
    /// 팬 개수 (FNum). 읽지 못했으면 nil이에요.
    private let fanCount: Int?
    /// 팬마다 최소·최대 회전수 (바뀌지 않아서 한 번만 읽어요)
    private let fanRanges: [(minimum: Double?, maximum: Double?)]

    init() {
        let smc = SMC()
        self.smc = smc
        func available(_ keys: [String]) -> [String] {
            guard let smc else {
                return []
            }
            return keys.filter { smc.hasKey($0) }
        }
        cpuKeys = available(ThermalCollector.cpuKeys)
        gpuKeys = available(ThermalCollector.gpuKeys)
        aneKeys = available(ThermalCollector.aneKeys)
        batteryKeys = available(ThermalCollector.batteryKeys)
        ssdKeys = available(ThermalCollector.ssdKeys)
        let fanCount = smc?.number("FNum").flatMap { $0.isFinite ? Int(min(max($0, 0), 16)) : nil }
        self.fanCount = fanCount
        fanRanges = (0..<(fanCount ?? 0)).map { (id: Int) -> (minimum: Double?, maximum: Double?) in
            (minimum: smc?.number("F\(id)Mn"), maximum: smc?.number("F\(id)Mx"))
        }
    }

    /// 온도·팬과 ANE 온도를 채우고, 그래프에 남길 계열을 돌려줘요.
    /// ANE 온도는 IOReport의 'ANE 사용 중'을 보고 정해서, IOReportCollector 다음에 불러야 해요.
    func update(_ snapshot: inout MonitorSnapshot, now: Date) -> [Metric] {
        snapshot.thermal.cpuMax = temperature(cpuKeys, at: now)
        snapshot.thermal.gpuMax = temperature(gpuKeys, at: now)
        snapshot.thermal.battery = temperature(batteryKeys, at: now)
        snapshot.thermal.ssd = temperature(ssdKeys, at: now)
        snapshot.ane.temperature = aneTemperature(isActive: snapshot.ane.isActive, at: now)
        snapshot.thermal.fans = fans(at: now)
        return [.cpuTemperature, .gpuTemperature] + (0..<(fanCount ?? 0)).map { Metric.fan($0) }
    }

    // MARK: - 온도

    /// 묶음의 최고 온도. 0 이하(꺼진 센서)는 빼요.
    private func temperature(_ keys: [String], minimum: Double = 0, at date: Date) -> Reading<Double> {
        guard let smc else {
            return .failed("SMC를 열지 못했어요.")
        }
        guard !keys.isEmpty else {
            return .unsupported
        }
        switch SensorGroupReading.from(keys.map { smc.number($0) }, minimum: minimum) {
        case .highest(let value):
            return .ok(value, at: date)
        case .off:
            return .off
        case .unreadable:
            return .failed("온도 센서를 읽지 못했어요.")
        }
    }

    /// ANE 온도는 ANE가 켜져 있을 때만 보여줘요. 꺼져 있으면 '꺼짐'이에요.
    private func aneTemperature(isActive: Reading<Bool>, at date: Date) -> Reading<Double> {
        // IOReport가 '쉬는 중'이라고 하면 센서를 읽지 않아요. 상태를 모를 때는 센서 값만으로 판단해요.
        if isActive.okValue == false {
            return .off
        }
        let reading = temperature(aneKeys, minimum: ThermalCollector.aneMinimum, at: date)
        // 잠깐만 켜지면 센서가 값을 주기 전에 다시 꺼지기도 해요. (확인할 때 '사용 중'인데 센서는 0·멈춘 값이었어요)
        // 이때는 '꺼짐' 대신 '준비 중'으로 보여줘요.
        if isActive.okValue == true, reading.state == .off {
            return .preparing
        }
        return reading
    }

    // MARK: - 팬

    private func fans(at date: Date) -> Reading<[FanReading]> {
        guard let smc else {
            return .failed("SMC를 열지 못했어요.")
        }
        guard let fanCount else {
            return .failed("팬 개수를 읽지 못했어요.")
        }
        guard fanCount > 0 else {
            // 팬이 없는 Mac이에요.
            return .unsupported
        }
        let fans = (0..<fanCount).map { (id: Int) -> FanReading in
            let rpm: Reading<Double>
            if let value = smc.number("F\(id)Ac"), value.isFinite {
                // 읽기에 성공한 0은 '정지'예요. (읽지 못한 것과 구분해요)
                rpm = .ok(max(value, 0), at: date)
            } else {
                rpm = .failed("팬 회전수를 읽지 못했어요.")
            }
            // fanRanges는 init에서 팬 개수만큼 만들어서 id가 늘 들어 있어요.
            return FanReading(id: id, rpm: rpm,
                              minimumRPM: fanRanges[id].minimum, maximumRPM: fanRanges[id].maximum,
                              mode: ThermalCollector.fanMode(smc.number("F\(id)Md")))
        }
        return .ok(fans, at: date)
    }

    /// 팬 모드 (F0Md). 0과 3은 시스템이 알아서 조절해요. (이 Mac은 3이었어요) 1은 수동이에요.
    private static func fanMode(_ value: Double?) -> FanMode {
        guard let value, value.isFinite else {
            return .unknown
        }
        switch Int(value) {
        case 0, 3:
            return .automatic
        case 1:
            return .manual
        default:
            return .unknown
        }
    }
}
