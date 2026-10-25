import Darwin
import Foundation
import IOKit
import IOKit.ps

/// IOPowerSources가 알려 주는 내장 배터리 정보예요. (잔량·충전 상태·남은 시간)
nonisolated struct PowerSourceInfo: Hashable, Sendable {
    /// 잔량 (0–100 %)
    var level: Double?
    /// 전원 어댑터에 연결돼 있는지 ('AC Power')
    var isOnACPower: Bool
    var isCharging: Bool
    var isCharged: Bool
    /// 방전 중 남은 시간 (분). 계산 중이면 -1이에요.
    var minutesToEmpty: Int?
    /// 완충까지 걸리는 시간 (분). 계산 중이면 -1이에요.
    var minutesToFull: Int?

    /// 충전 상태. 어댑터에 연결됐는데 충전하지도, 완충되지도 않았으면 '충전 보류'예요. (최적화된 충전 등)
    var chargeState: BatteryState {
        guard isOnACPower else {
            return .discharging
        }
        if isCharging {
            return .charging
        }
        if isCharged {
            return .charged
        }
        return .onHold
    }
}

extension PowerSourceInfo {
    /// IOPowerSources 설명 사전에서 만들어요. (키 이름은 IOPSKeys.h)
    nonisolated init(_ description: [String: Any]) {
        let current = (description["Current Capacity"] as? NSNumber)?.doubleValue
        let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue
        if let current, let maximum, maximum > 0 {
            level = min(max(current / maximum * 100, 0), 100)
        } else {
            level = nil
        }
        isOnACPower = description["Power Source State"] as? String == "AC Power"
        isCharging = description["Is Charging"] as? Bool ?? false
        isCharged = description["Is Charged"] as? Bool ?? false
        minutesToEmpty = (description["Time to Empty"] as? NSNumber)?.intValue
        minutesToFull = (description["Time to Full Charge"] as? NSNumber)?.intValue
    }
}

/// 전원 정보를 읽은 결과예요.
nonisolated enum PowerSourceResult: Hashable, Sendable {
    case battery(PowerSourceInfo)
    /// 내장 배터리가 없는 Mac이에요.
    case noBattery
    /// 전원 정보를 읽지 못했어요.
    case failed
}

/// IOPowerSources(공개 API)에서 내장 배터리 정보를 읽어요.
nonisolated enum PowerSourceReader {
    static func read() -> PowerSourceResult {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .failed
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery" else {
                continue
            }
            return .battery(PowerSourceInfo(description))
        }
        return .noBattery
    }
}

/// AppleSmartBattery(IORegistry)에서 읽는 측정값이에요. (전압·전류·사이클)
/// macOS 27은 설계 용량·성능 상태 같은 값을 여기에서 빼서, 그 값들은 BatteryHealthReader로 읽어요.
nonisolated struct SmartBatteryInfo: Hashable, Sendable {
    /// 전압 (mV)
    var voltage: Double?
    /// 전류 (mA). 배터리로 들어가면 +, 나오면 −예요.
    var amperage: Double?
    var cycleCount: Int?
    /// 배터리가 값을 마지막으로 새로 알려 준 시각 (`UpdateTime`). M1 Pro·macOS 27에서는 약 1분마다 바뀌었어요.
    var updatedAt: Date?

    /// 순전력 (W) = 전압 × 전류. 배터리로 들어가면 +, 나오면 −예요.
    var netPower: Double? {
        guard let voltage, let amperage else {
            return nil
        }
        return voltage * amperage / 1_000_000
    }

    /// AppleSmartBattery에서 필요한 값만 읽어요. (속성 전체를 복사하면 큰 기록 사전까지 딸려 와요)
    /// 배터리가 없으면 nil이에요.
    static func read() -> SmartBatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
        }
        // 전류는 방전 중에 음수예요. 큰 부호 없는 수로 들어 있을 수도 있어서 64비트 부호 있는 정수로 읽어요.
        return SmartBatteryInfo(voltage: number("Voltage")?.doubleValue,
                                amperage: number("Amperage").map { Double($0.int64Value) },
                                cycleCount: number("CycleCount")?.intValue,
                                updatedAt: number("UpdateTime").map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
}

/// 배터리 성능 상태와 최대 용량이에요. (시스템 설정 > 배터리 > 배터리 성능 상태와 같은 값)
nonisolated struct BatteryHealth: Hashable, Sendable {
    /// 성능 상태 (예: 'Good')
    var condition: String?
    /// 최대 용량 (새 배터리 대비 %)
    var maximumCapacity: Double?
}

/// macOS가 계산한 성능 상태와 최대 용량을 system_profiler(SPPowerDataType)로 읽어요.
/// macOS 27은 이 값을 IORegistry로 알려 주지 않고, 설계 용량 대비 비율을 직접 계산하면 83~86%로 흔들려서
/// 시스템 설정(84%)과 맞지 않았어요. (2026-10-25 확인)
nonisolated enum BatteryHealthReader {
    /// 다른 프로그램을 실행해서 기다려야 하니 메인 스레드가 아닌 곳에서 불러요. 읽지 못하면 nil이에요.
    static func read() -> BatteryHealth? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // 출력을 다 읽은 뒤에 끝나기를 기다려요. (먼저 기다리면 출력이 많을 때 서로 멈출 수 있어요)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return parse(data)
    }

    /// system_profiler -json 출력에서 배터리 성능 정보를 꺼내요.
    static func parse(_ data: Data) -> BatteryHealth? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else {
            return nil
        }
        for item in items {
            guard let health = item["sppower_battery_health_info"] as? [String: Any] else {
                continue
            }
            // 최대 용량은 '84%' 같은 글자예요.
            let percentText = health["sppower_battery_health_maximum_capacity"] as? String
            let percent = percentText.flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
            return BatteryHealth(condition: health["sppower_battery_health"] as? String, maximumCapacity: percent)
        }
        return nil
    }
}

/// 배터리를 재요. 잔량·충전 상태·남은 시간은 IOPowerSources, 순전력·사이클 수는 AppleSmartBattery,
/// 성능 상태·최대 용량은 system_profiler에서 읽어요.
/// 배터리 값은 천천히 바뀌어서 패널이 열려 있으면 5초, 닫혀 있으면 30초마다 재요. (설계 문서 4장)
final class BatteryCollector {
    /// 마지막으로 잰 때 (잠든 시간도 세는 시계, 나노초). 깨어나면 바로 다시 재려고 이 시계를 써요.
    private var lastMeasuredAt: UInt64 = 0
    /// 마지막으로 읽는 데 성공한 성능 정보와 그 측정 시각
    private var health: BatteryHealth?
    private var healthReadAt: Date?
    /// 마지막으로 읽으려 한 때 (잠든 시간도 세는 시계, 나노초)와 그때 성공했는지.
    /// 아직 읽으려 한 적이 없으면 '준비 중', 읽어 본 뒤에도 값이 없으면 '읽지 못함'이에요.
    private var healthAttemptedAt: UInt64?
    private var healthAttemptSucceeded = false
    private var healthTask: Task<Void, Never>?

    /// 성능 정보는 몇 주에 걸쳐 바뀌어서 30분마다만 다시 읽어요. 실패했으면 5분 뒤에 다시 해 봐요.
    private static let healthRefreshInterval: UInt64 = 30 * 60 * 1_000_000_000
    private static let healthRetryInterval: UInt64 = 5 * 60 * 1_000_000_000

    /// 배터리는 순전력·사이클 수를 약 1분마다 새로 알려 줘요. 3분이 지나도 그대로면 '오래됨'이에요.
    private static let gaugeFreshness: TimeInterval = 3 * 60
    /// 성능 상태·최대 용량은 30분마다 읽어요. 다시 읽기가 실패해서 1시간 5분이 지나면 '오래됨'이에요.
    private static let healthFreshness: TimeInterval = 65 * 60

    /// 새로 쟀으면 true예요. 잴 때가 아니어도 매번, 측정 시각이 오래된 값은 '오래됨'으로 바꿔요.
    func update(_ battery: inout BatterySnapshot, now: Date, panelVisible: Bool) -> Bool {
        defer { BatteryCollector.checkFreshness(&battery, now: now) }
        let clock = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        // 수집 일정의 간격(1초·5초)에 맞춰 조금 일찍(0.5초) 재도 되게 해요.
        let interval: UInt64 = panelVisible ? 4_500_000_000 : 29_500_000_000
        if lastMeasuredAt != 0, clock &- lastMeasuredAt < interval {
            return false
        }
        lastMeasuredAt = clock

        switch PowerSourceReader.read() {
        case .noBattery:
            battery = BatterySnapshot(level: .unsupported, chargeState: .unsupported, netPower: .unsupported,
                                      timeRemaining: .unsupported, condition: .unsupported,
                                      maximumCapacity: .unsupported, cycleCount: .unsupported)
            return true
        case .failed:
            let failure = "전원 정보를 읽지 못했어요."
            battery.level = .failed(failure)
            battery.chargeState = .failed(failure)
            battery.timeRemaining = .failed(failure)
        case .battery(let info):
            battery.level = info.level.map { Reading.ok($0, at: now) } ?? .failed("배터리 잔량을 읽지 못했어요.")
            battery.chargeState = .ok(info.chargeState, at: now)
            battery.timeRemaining = BatteryCollector.timeRemaining(info, at: now)
        }

        if let info = SmartBatteryInfo.read() {
            // 배터리 값은 약 1분마다 새로 바뀌어요. 읽은 때가 아니라 배터리가 값을 알려 준 때를 측정 시각으로 둬요.
            // (시계가 어긋나 미래 시각이 나오면 지금으로 둬요)
            let measuredAt = info.updatedAt.map { min($0, now) } ?? now
            battery.netPower = info.netPower.map { Reading.ok($0, at: measuredAt) } ?? .failed("배터리 전압·전류를 읽지 못했어요.")
            battery.cycleCount = info.cycleCount.map { Reading.ok($0, at: measuredAt) } ?? .failed("사이클 수를 읽지 못했어요.")
        } else {
            battery.netPower = .failed("배터리 측정값을 읽지 못했어요.")
            battery.cycleCount = .failed("배터리 측정값을 읽지 못했어요.")
        }

        refreshHealthIfDue(clock: clock)
        applyHealth(&battery)
        return true
    }

    /// 출처가 따로 값을 내는 항목만 봐요. 잔량·충전 상태·남은 시간은 잴 때마다 새로 묻는 값이라 보지 않아요.
    private static func checkFreshness(_ battery: inout BatterySnapshot, now: Date) {
        battery.netPower = battery.netPower.checkedFreshness(now: now, limit: gaugeFreshness)
        battery.cycleCount = battery.cycleCount.checkedFreshness(now: now, limit: gaugeFreshness)
        battery.condition = battery.condition.checkedFreshness(now: now, limit: healthFreshness)
        battery.maximumCapacity = battery.maximumCapacity.checkedFreshness(now: now, limit: healthFreshness)
    }

    // MARK: - IOPowerSources

    /// macOS가 추정한 시간이에요. 방전 중이면 남은 시간, 충전 중이면 완충까지. 계산 중이면 '준비 중'이에요.
    private static func timeRemaining(_ info: PowerSourceInfo, at date: Date) -> Reading<Double> {
        let minutes: Int?
        switch info.chargeState {
        case .discharging:
            minutes = info.minutesToEmpty
        case .charging:
            minutes = info.minutesToFull
        case .charged, .onHold:
            // 완충·충전 보류에는 남은 시간이 없어요.
            return .notMeasurable("완충되었거나 충전을 보류하고 있어요.")
        }
        guard let minutes else {
            return .failed("macOS가 남은 시간을 알려 주지 않았어요.")
        }
        guard minutes >= 0 else {
            // -1: macOS가 아직 계산 중이에요.
            return .preparing
        }
        return .ok(Double(minutes) * 60, at: date)
    }

    // MARK: - 성능 상태·최대 용량 (system_profiler)

    /// 때가 되면 뒤에서 다시 읽어요. 결과는 다음 측정 때부터 화면에 들어가요.
    private func refreshHealthIfDue(clock: UInt64) {
        guard healthTask == nil else {
            return
        }
        if let healthAttemptedAt {
            let wait = healthAttemptSucceeded ? BatteryCollector.healthRefreshInterval : BatteryCollector.healthRetryInterval
            guard clock &- healthAttemptedAt >= wait else {
                return
            }
        }
        healthTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                BatteryHealthReader.read()
            }.value
            guard let self else {
                return
            }
            self.healthAttemptedAt = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            self.healthAttemptSucceeded = result != nil
            // 다시 읽다가 실패하면 앞서 읽은 값을 그 측정 시각과 함께 그대로 둬요.
            if let result {
                self.health = result
                self.healthReadAt = Date()
            }
            self.healthTask = nil
        }
    }

    private func applyHealth(_ battery: inout BatterySnapshot) {
        guard let health, let healthReadAt else {
            if healthAttemptedAt == nil {
                battery.condition = .preparing
                battery.maximumCapacity = .preparing
            } else {
                battery.condition = .failed("배터리 성능 상태를 읽지 못했어요.")
                battery.maximumCapacity = .failed("배터리 성능 상태를 읽지 못했어요.")
            }
            return
        }
        if let condition = health.condition {
            battery.condition = .ok(BatteryCollector.conditionText(condition), at: healthReadAt)
        } else {
            battery.condition = .failed("성능 상태를 읽지 못했어요.")
        }
        if let maximum = health.maximumCapacity {
            battery.maximumCapacity = .ok(maximum, at: healthReadAt)
        } else {
            battery.maximumCapacity = .failed("최대 용량을 읽지 못했어요.")
        }
    }

    /// system_profiler의 성능 상태를 시스템 설정의 말로 바꿔요. ('Good' → '정상')
    private static func conditionText(_ condition: String) -> String {
        switch condition {
        case "Good", "Normal":
            return "정상"
        case "Fair", "Poor", "Check Battery", "Service Recommended", "Replace Soon", "Replace Now", "Service Battery":
            return "서비스 권장"
        default:
            return condition
        }
    }
}
