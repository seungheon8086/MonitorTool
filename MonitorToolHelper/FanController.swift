import Foundation
import IOKit
import IOKit.pwr_mgt
import notify

/// 팬 제어를 맡아요. (docs/FAN_CONTROL.md)
/// - 고정 요청은 하나만 메모리에 기억해요. 디스크에 남기지 않아서, 보조 프로그램이 다시 뜨면 항상 시스템 제어에서 시작해요.
/// - 고정 중에는 1초마다 시간·열 압력·온도·모드를 확인해 FanSafetyRules대로 시스템 제어로 돌려줘요.
/// - 잠들기 직전 시스템 제어로 돌려 두고, 깨어나면 남은 시간이 있을 때만 다시 적용해요.
/// - 시작할 때 수동(1)으로 남은 팬이 있으면 시스템 제어로 정리해요. (맡은 요청이 없으니까요)
/// 상태는 모두 queue 안에서만 읽고 바꿔요.
final class FanController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.seungheon.MonitorTool.helper.fan")
    private let smc: SMC?
    private let fans: [Fan]

    private var active: FanControlRequest?
    private var appliedAt = Date.distantPast
    private var confirmed = false
    private var suspendedForSleep = false
    private var lastReturn: FanReturnEvent?
    private var timer: DispatchSourceTimer?

    private var pressureToken: Int32 = 0
    private var pressureRegistered = false

    private var rootPort: io_connect_t = 0
    // periphery:ignore - 잠자기 알림 등록을 붙잡아 둬요.
    private var powerNotifyPort: IONotificationPortRef?
    // periphery:ignore - 잠자기 알림 등록을 붙잡아 둬요.
    private var powerNotifier: io_object_t = 0

    /// 팬 하나 (SMC 번호와 최소·최대 회전수)
    struct Fan {
        let id: Int
        let minimum: Double
        let maximum: Double
        var modeKey: String { "F\(id)Md" }
        var targetKey: String { "F\(id)Tg" }
    }

    /// 앱의 ThermalCollector와 같은 대표 센서예요.
    private static let cpuTemperatureKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H",
                                             "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b"]
    /// GPU 보정 키와 원래 센서. 원래 센서가 0(꺼짐)이면 보정 키는 9.2 °C를 줘서 쓰지 않아요. (앱의 ThermalCollector와 같은 규칙)
    private static let gpuTemperaturePairs: [(derived: String, raw: String)] = [("Tg05", "Tg04"), ("Tg0D", "Tg0C")]

    // IOKit 전원 알림 번호 (iokit_common_msg 매크로는 Swift로 들어오지 않아서 숫자로 적어요)
    private static let messageCanSystemSleep: UInt32 = 0xE000_0270
    private static let messageSystemWillSleep: UInt32 = 0xE000_0280
    private static let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

    init() {
        let smc = SMC()
        var found: [Fan] = []
        if let smc, let count = smc.number("FNum") {
            for id in 0..<max(Int(count), 0) {
                if let minimum = smc.number("F\(id)Mn"), let maximum = smc.number("F\(id)Mx"), maximum > minimum {
                    found.append(Fan(id: id, minimum: minimum, maximum: maximum))
                }
            }
        }
        self.smc = smc
        fans = found

        var token: Int32 = 0
        pressureRegistered = notify_register_check("com.apple.system.thermalpressurelevel", &token) == 0
        pressureToken = token

        queue.sync {
            cleanUpLeftovers()
        }
        registerForSleep()
        NSLog("MonitorToolHelper: 팬 %ld개 (%@)", fans.count,
              fans.map { "F\($0.id) \(Int($0.minimum))~\(Int($0.maximum))" }.joined(separator: ", "))
    }

    // MARK: - XPC에서 부르는 일

    /// 요청을 적용하고 (상태 JSON, 거절·실패 이유)를 돌려줘요.
    func apply(_ data: Data) -> (Data?, String?) {
        queue.sync { () -> (Data?, String?) in
            guard let request = try? JSONDecoder().decode(FanControlRequest.self, from: data) else {
                return (encodedState(), "요청 형식 오류")
            }
            if request.isSystem {
                if active != nil || suspendedForSleep {
                    writeSystemModes()
                }
                active = nil
                suspendedForSleep = false
                lastReturn = nil
                stopTimer()
                NSLog("MonitorToolHelper: 팬 시스템 제어 (앱 요청)")
                return (encodedState(), nil)
            }
            if let problem = validate(request) {
                return (encodedState(), problem)
            }
            if let problem = writeTargets(request.targets) {
                writeSystemModes()
                active = nil
                suspendedForSleep = false
                lastReturn = FanReturnEvent(reason: .writeFailed, at: Date())
                stopTimer()
                NSLog("MonitorToolHelper: 팬 고정 실패 (%@)", problem)
                return (encodedState(), "\(FanReturnReason.writeFailed.text). \(problem)")
            }
            active = request
            appliedAt = Date()
            confirmed = false
            suspendedForSleep = false
            lastReturn = nil
            startTimer()
            NSLog("MonitorToolHelper: 팬 고정 %@ (%@)", request.label,
                  request.targets.map { "\(Int($0.smcValue))" }.joined(separator: ", "))
            return (encodedState(), nil)
        }
    }

    /// 지금 상태 JSON
    func stateData() -> Data? {
        queue.sync { () -> Data? in
            encodedState()
        }
    }

    /// 앱과의 연결이 모두 끊겼을 때 ('계속 유지'라도 시스템 제어로)
    func appDisconnected() {
        queue.async {
            guard self.active != nil || self.suspendedForSleep else {
                return
            }
            self.writeSystemModes()
            self.finish(.appDisconnected)
        }
    }

    /// 보조 프로그램이 끝나기 직전 (SIGTERM, 연결 없음, 실행 파일 교체)
    func shutdown() {
        queue.sync {
            if active != nil || suspendedForSleep {
                writeSystemModes()
                NSLog("MonitorToolHelper: 끝나기 전에 팬을 시스템 제어로 돌림")
            }
            active = nil
            suspendedForSleep = false
            stopTimer()
        }
    }

    // MARK: - 쓰기 (queue 안에서만 불러요)

    /// 요청이 이 Mac의 팬에 맞는지. 맞지 않으면 거절 이유
    private func validate(_ request: FanControlRequest) -> String? {
        guard smc != nil, !fans.isEmpty else {
            return "SMC 연결 실패"
        }
        guard request.targets.count == fans.count else {
            return "팬 수 불일치"
        }
        for (fan, target) in zip(fans, request.targets) {
            if case .rpm(let value) = target {
                guard Double(value) >= fan.minimum.rounded(.down), Double(value) <= fan.maximum.rounded(.up) else {
                    return "목표 RPM 범위 초과 (팬 \(fan.id): \(Int(fan.minimum))–\(Int(fan.maximum)))"
                }
            }
        }
        if let expiresAt = request.expiresAt, expiresAt <= Date() {
            return "복귀 시각 경과"
        }
        return nil
    }

    /// 팬마다 수동(1) → 목표 순서로 써요. 실패하면 이유
    private func writeTargets(_ targets: [FanTarget]) -> String? {
        guard let smc else {
            return SMCError.notOpen.text
        }
        for (fan, target) in zip(fans, targets) {
            if case .failure(let error) = smc.write(fan.modeKey, 1) {
                return error.text
            }
            if case .failure(let error) = smc.write(fan.targetKey, target.smcValue) {
                return error.text
            }
        }
        return nil
    }

    /// 수동(1)인 팬만 시스템 제어(0)로 써요. 시스템은 알아서 0이나 3으로 정해요.
    private func writeSystemModes() {
        guard let smc else {
            return
        }
        for fan in fans where smc.number(fan.modeKey) == 1 {
            if case .failure(let error) = smc.write(fan.modeKey, 0) {
                NSLog("MonitorToolHelper: 팬 %ld 시스템 제어로 돌리지 못함 (%@)", fan.id, error.text)
            }
        }
    }

    /// 시작할 때 수동으로 남은 팬 정리
    private func cleanUpLeftovers() {
        guard let smc else {
            return
        }
        let leftovers = fans.filter { smc.number($0.modeKey) == 1 }
        guard !leftovers.isEmpty else {
            return
        }
        NSLog("MonitorToolHelper: 수동으로 남은 팬 %ld개를 시스템 제어로 정리", leftovers.count)
        writeSystemModes()
    }

    /// 스스로 시스템 제어로 돌아간 것을 기록해요.
    private func finish(_ reason: FanReturnReason) {
        active = nil
        suspendedForSleep = false
        lastReturn = FanReturnEvent(reason: reason, at: Date())
        stopTimer()
        NSLog("MonitorToolHelper: 팬 시스템 제어 복귀 (%@)", reason.text)
    }

    private func encodedState() -> Data? {
        let state = FanControlState(active: active, lastReturn: lastReturn)
        return try? JSONEncoder().encode(state)
    }

    // MARK: - 1초 확인 (queue 안에서만 불러요)

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + FanControlLimits.checkInterval,
                       repeating: FanControlLimits.checkInterval,
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.check()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func check() {
        guard let request = active, !suspendedForSleep, let smc else {
            return
        }
        let input = FanCheckInput(
            now: Date(),
            appliedAt: appliedAt,
            expiresAt: request.expiresAt,
            confirmed: confirmed,
            thermalPressure: thermalPressure(),
            cpuMax: FanSafetyRules.highest(Self.cpuTemperatureKeys.map { smc.number($0) }),
            gpuMax: FanSafetyRules.highest(Self.gpuTemperaturePairs.map { pair -> Double? in
                // 원래 센서가 없는 Mac이면 보정 키만 보고, 20 °C 이하 거르기(highest)에 맡겨요.
                if let raw = smc.number(pair.raw), raw <= 0 { return nil }
                return smc.number(pair.derived)
            }),
            modes: fans.map { smc.number($0.modeKey) },
            targets: fans.map { smc.number($0.targetKey) },
            expected: request.targets.map(\.smcValue))
        switch FanSafetyRules.decide(input) {
        case .keep:
            break
        case .confirm:
            confirmed = true
        case .returnToSystem(let reason):
            writeSystemModes()
            finish(reason)
        case .abandon(let reason):
            finish(reason)
        }
    }

    private func thermalPressure() -> UInt64? {
        guard pressureRegistered else {
            return nil
        }
        var state: UInt64 = 0
        guard notify_get_state(pressureToken, &state) == 0 else {
            return nil
        }
        return state
    }

    // MARK: - 잠자기·깨어남

    private func registerForSleep() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let root = IORegisterForSystemPower(context, &port, FanController.powerCallback(), &notifier)
        guard root != 0, let port else {
            NSLog("MonitorToolHelper: 잠자기 알림 등록 실패")
            return
        }
        IONotificationPortSetDispatchQueue(port, queue)
        queue.sync {
            rootPort = root
            powerNotifyPort = port
            powerNotifier = notifier
        }
    }

    /// C 콜백은 문맥을 잡을 수 없어서, 정적 함수 안에서 만든 클로저로 넘겨요.
    private static func powerCallback() -> IOServiceInterestCallback {
        { context, _, messageType, messageArgument in
            guard let context else {
                return
            }
            let controller = Unmanaged<FanController>.fromOpaque(context).takeUnretainedValue()
            controller.handlePower(messageType, argument: messageArgument)
        }
    }

    /// 전원 알림 (queue 위에서 불려요)
    private func handlePower(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch message {
        case Self.messageCanSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case Self.messageSystemWillSleep:
            if active != nil {
                writeSystemModes()
                suspendedForSleep = true
                stopTimer()
                NSLog("MonitorToolHelper: 잠들기 전 팬 시스템 제어 (깨어나면 다시 적용)")
            }
            IOAllowPowerChange(rootPort, notificationID)
        case Self.messageSystemHasPoweredOn:
            resumeAfterWake()
        default:
            break
        }
    }

    private func resumeAfterWake() {
        guard suspendedForSleep, let request = active else {
            return
        }
        suspendedForSleep = false
        if let expiresAt = request.expiresAt, Date() >= expiresAt {
            finish(.timeEnded)
            return
        }
        if let problem = writeTargets(request.targets) {
            writeSystemModes()
            finish(.writeFailed)
            NSLog("MonitorToolHelper: 깨어난 뒤 다시 적용 실패 (%@)", problem)
            return
        }
        appliedAt = Date()
        confirmed = false
        startTimer()
        NSLog("MonitorToolHelper: 깨어난 뒤 팬 고정 다시 적용")
    }
}
