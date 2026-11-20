import Foundation
import Observation

// 팬 제어의 앱 쪽이에요. (docs/FAN_CONTROL.md)
// 프리셋·기본 복귀 시간·직접 정하기의 마지막 값을 저장하고, 보조 프로그램에 고정·시스템 제어를 요청해요.
// 실제로 팬에 쓰고 안전장치를 지키는 일은 보조 프로그램(FanController)이 해요.

/// 고정 RPM 프리셋 하나
nonisolated struct FanPreset: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// 사용자가 입력한 이름 (길이 제한 없음)
    var name: String
    /// 팬마다 목표 (SMC 순서: 0 = 왼쪽, 1 = 오른쪽)
    var targets: [FanTarget]
}

/// 시스템 제어로 돌아갈 때까지의 시간
nonisolated enum FanHold: Codable, Hashable, Sendable {
    case minutes(Int)
    case keep

    /// 단추로 고르는 분 (그 밖은 '직접')
    static let presetMinutes = [5, 15, 30, 60]
    static let standard = FanHold.minutes(30)

    /// '30분', '계속 유지'
    var text: String {
        switch self {
        case .minutes(let value): "\(value)분"
        case .keep: "계속 유지"
        }
    }
}

/// 팬 하나의 회전수 범위 (SMC에서 한 번 읽어요)
nonisolated struct FanLimit: Hashable, Sendable {
    let id: Int
    let minimum: Int
    let maximum: Int

    /// 고정에 쓸 수 있는 값인지 (정지는 늘 돼요)
    func accepts(_ target: FanTarget) -> Bool {
        switch target {
        case .stopped: true
        case .rpm(let value): value >= minimum && value <= maximum
        }
    }
}

@Observable
final class FanControlModel {
    /// 프리셋 (설정 창 '팬' 탭에서 만든 순서)
    private(set) var presets: [FanPreset]
    /// 패널에서 미리 골라져 있을 복귀 시간
    private(set) var defaultHold: FanHold
    /// 직접 정하기로 마지막에 적용한 값 (다음 직접 정하기의 처음 값)
    private(set) var lastCustom: [FanTarget]?
    /// 보조 프로그램이 알려 준 지금 상태. 아직 모르면 nil이에요.
    private(set) var state: FanControlState?
    /// 마지막 요청이 거절되거나 실패한 이유 (개조식)
    private(set) var problem: String?
    /// 요청을 보내고 답을 기다리는 중
    private(set) var isSending = false
    /// 이 Mac의 팬 (SMC 순서)
    let limits: [FanLimit]

    @ObservationIgnored private let helper: HelperController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isRefreshing = false

    private static let presetsKey = "fanPresets"
    private static let defaultHoldKey = "fanDefaultHold"
    private static let lastCustomKey = "fanLastCustom"

    /// - Parameter limits: 팬 범위. nil이면 SMC에서 읽어요. (미리보기에서는 직접 넣어요)
    init(helper: HelperController, defaults: UserDefaults = .standard, limits: [FanLimit]? = nil) {
        self.helper = helper
        self.defaults = defaults
        self.limits = limits ?? FanControlModel.readLimits()
        presets = FanControlModel.load([FanPreset].self, key: FanControlModel.presetsKey, from: defaults) ?? []
        defaultHold = FanControlModel.load(FanHold.self, key: FanControlModel.defaultHoldKey, from: defaults)
            ?? FanHold.standard
        lastCustom = FanControlModel.load([FanTarget].self, key: FanControlModel.lastCustomKey, from: defaults)
    }

    /// 보조 프로그램이 동작 중이라 팬 제어를 쓸 수 있는지
    var isAvailable: Bool {
        helper.status == .enabled
    }

    /// 보조 프로그램 상태 (팬 제어 상태 상자에 써요)
    var helperStatus: HelperStatus {
        helper.status
    }

    /// 지금 고정 중인 요청
    var active: FanControlRequest? {
        guard isAvailable else { return nil }
        return state?.active
    }

    /// 직접 정하기의 처음 값 (마지막에 쓴 값, 없으면 팬마다 2,000 근처)
    var initialCustom: [FanTarget] {
        if let lastCustom, lastCustom.count == limits.count {
            return lastCustom
        }
        return limits.map { .rpm(min(max(2000, $0.minimum), $0.maximum)) }
    }

    // MARK: - 프리셋

    func addPreset(name: String, targets: [FanTarget]) {
        presets.append(FanPreset(id: UUID(), name: name, targets: targets))
        savePresets()
    }

    func updatePreset(_ preset: FanPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        savePresets()
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets()
    }

    /// 순서를 한 칸 위(-1)나 아래(+1)로 옮겨요.
    func movePreset(id: UUID, by offset: Int) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard presets.indices.contains(target) else { return }
        presets.swapAt(index, target)
        savePresets()
    }

    func setDefaultHold(_ hold: FanHold) {
        guard defaultHold != hold else { return }
        defaultHold = hold
        FanControlModel.save(hold, key: FanControlModel.defaultHoldKey, to: defaults)
    }

    /// 프리셋과 팬 수가 맞고 값이 범위 안인지
    func isValid(_ targets: [FanTarget]) -> Bool {
        targets.count == limits.count && zip(limits, targets).allSatisfy { $0.accepts($1) }
    }

    // MARK: - 보조 프로그램에 요청

    /// 고정해요. 성공하면 보조 프로그램이 돌려준 상태로 바뀌어요.
    /// - Parameter isCustom: 직접 정하기면 그 값을 다음 처음 값으로 기억해요.
    func apply(targets: [FanTarget], label: String, hold: FanHold, isCustom: Bool) {
        guard isValid(targets), !isSending else { return }
        if isCustom {
            lastCustom = targets
            FanControlModel.save(targets, key: FanControlModel.lastCustomKey, to: defaults)
        }
        let expiresAt: Date?
        switch hold {
        case .minutes(let minutes): expiresAt = Date().addingTimeInterval(TimeInterval(max(minutes, 1)) * 60)
        case .keep: expiresAt = nil
        }
        send(FanControlRequest(targets: targets, expiresAt: expiresAt, label: label))
    }

    /// 시스템 제어로 돌려요.
    func returnToSystem() {
        guard !isSending else { return }
        send(.system)
    }

    /// 지금 상태를 다시 물어요. (수집 일정이 값을 모을 때마다 불러요)
    func refresh() {
        guard isAvailable else {
            if state != nil {
                state = nil
            }
            return
        }
        guard !isRefreshing, !isSending else { return }
        isRefreshing = true
        helper.fetchFanState { [weak self] newState, _ in
            guard let self else { return }
            self.isRefreshing = false
            if let newState, newState != self.state {
                self.state = newState
            }
        }
    }

    private func send(_ request: FanControlRequest) {
        isSending = true
        problem = nil
        helper.sendFanControl(request) { [weak self] newState, newProblem in
            guard let self else { return }
            self.isSending = false
            if let newState {
                self.state = newState
            }
            self.problem = newProblem
            if let newProblem {
                print("⚠️ 팬 제어: \(newProblem)")
            }
        }
    }

    // MARK: - 저장

    private func savePresets() {
        FanControlModel.save(presets, key: FanControlModel.presetsKey, to: defaults)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, key: String, from defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<Value: Encodable>(_ value: Value, key: String, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    /// SMC에서 팬 수와 범위를 읽어요. (읽기만 해요)
    private static func readLimits() -> [FanLimit] {
        guard let smc = SMC(), let count = smc.number("FNum"), count >= 1 else { return [] }
        return (0..<Int(count)).compactMap { id in
            guard let minimum = smc.number("F\(id)Mn"), let maximum = smc.number("F\(id)Mx"),
                  minimum.isFinite, maximum.isFinite, maximum > minimum else { return nil }
            return FanLimit(id: id, minimum: Int(minimum.rounded(.up)), maximum: Int(maximum.rounded(.down)))
        }
    }
}

#if DEBUG
extension FanControlModel {
    /// 미리보기용: 이 Mac과 같은 팬 두 개, 프리셋 예시
    // periphery:ignore - 미리보기(#Preview)에서 써요.
    static func preview(state: FanControlState? = .idle, helperStatus: HelperStatus = .enabled) -> FanControlModel {
        let defaults = UserDefaults(suiteName: "FanControlPreview") ?? .standard
        let model = FanControlModel(helper: .preview(helperStatus), defaults: defaults,
                                    limits: [FanLimit(id: 0, minimum: 1499, maximum: 4296),
                                             FanLimit(id: 1, minimum: 1499, maximum: 4744)])
        model.presets = [FanPreset(id: UUID(), name: "게임할 때", targets: [.rpm(2000), .rpm(2300)]),
                         FanPreset(id: UUID(), name: "조용히 (왼쪽 정지)", targets: [.stopped, .rpm(1600)])]
        model.state = state
        return model
    }
}
#endif
