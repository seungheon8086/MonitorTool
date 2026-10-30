import Foundation

// 고정 중 1초마다 '그대로 둘지, 시스템 제어로 돌려줄지'를 정하는 규칙이에요.
// 상태를 갖지 않는 순수 값 타입이라, 같은 규칙을 Python으로 옮겨 경우별로 시험했어요.
// (docs/FAN_CONTROL.md '안전장치')

/// 한 번 확인할 때 읽은 값
struct FanCheckInput {
    var now: Date
    /// 고정한 시각 (쓰기를 마친 때)
    var appliedAt: Date
    /// 시스템 제어로 돌아갈 시각. nil이면 계속 유지
    var expiresAt: Date?
    /// 쓴 값이 반영된 것을 한 번이라도 확인했는지
    var confirmed: Bool
    /// macOS 열 압력 단계 (0 = 보통). 읽지 못하면 nil
    var thermalPressure: UInt64?
    /// CPU·GPU 최고 온도. 쓸 만한 값이 없으면 nil
    var cpuMax: Double?
    var gpuMax: Double?
    /// 팬마다 읽은 모드 (`F{i}Md`). 읽지 못하면 nil
    var modes: [Double?]
    /// 팬마다 읽은 목표 (`F{i}Tg`). 읽지 못하면 nil
    var targets: [Double?]
    /// 팬마다 우리가 쓴 목표
    var expected: [Double]
}

enum FanCheckDecision: Equatable {
    /// 그대로 둬요.
    case keep
    /// 쓴 값이 처음으로 반영된 것을 확인했어요.
    case confirm
    /// 모드를 시스템 제어(0)로 써서 돌려줘요.
    case returnToSystem(FanReturnReason)
    /// 다른 프로그램이나 시스템이 이미 가져갔어요. 다투지 않도록 아무것도 쓰지 않고 요청만 버려요.
    case abandon(FanReturnReason)
}

enum FanSafetyRules {
    static func decide(_ input: FanCheckInput) -> FanCheckDecision {
        if let expiresAt = input.expiresAt, input.now >= expiresAt {
            return .returnToSystem(.timeEnded)
        }
        if let pressure = input.thermalPressure, pressure != 0 {
            return .returnToSystem(.thermalPressure)
        }
        if let cpu = input.cpuMax, cpu >= FanControlLimits.temperatureLimit {
            return .returnToSystem(.cpuTemperature)
        }
        if let gpu = input.gpuMax, gpu >= FanControlLimits.temperatureLimit {
            return .returnToSystem(.gpuTemperature)
        }

        // 읽지 못한 값(nil)은 판단에 쓰지 않아요. 한 번 읽기에 실패했다고 놓지 않으려는 거예요.
        let readModes = input.modes.compactMap { $0 }
        let allManual = readModes.count == input.modes.count && readModes.allSatisfy { $0 == 1 }
        let someoneElseMode = readModes.contains { $0 != 1 }
        let targetMismatch = zip(input.targets, input.expected).contains { read, expected in
            guard let read else { return false }
            return abs(read - expected) >= 1
        }
        let allTargetsRead = input.targets.allSatisfy { $0 != nil }

        if !input.confirmed {
            if allManual, allTargetsRead, !targetMismatch {
                return .confirm
            }
            if input.now.timeIntervalSince(input.appliedAt) >= FanControlLimits.confirmTimeout {
                return .returnToSystem(.writeFailed)
            }
            return .keep
        }

        if someoneElseMode || targetMismatch {
            return .abandon(.otherController)
        }
        return .keep
    }

    /// 온도 값 목록에서 쓸 만한 최고값 (낮은 값은 센서 꺼짐으로 봐요)
    static func highest(_ values: [Double?]) -> Double? {
        values.compactMap { $0 }
            .filter { $0.isFinite && $0 > FanControlLimits.minimumPlausibleTemperature }
            .max()
    }
}
