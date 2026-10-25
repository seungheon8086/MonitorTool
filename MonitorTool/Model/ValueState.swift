import Foundation

/// 값 하나의 상태예요. 화면은 이 상태를 보고 숫자 대신 알맞은 표시를 해요.
/// 읽지 못한 값을 0으로 바꾸지 않으려고 상태를 값과 함께 가지고 다녀요. (설계 문서 3장)
nonisolated enum ValueState: Hashable, Sendable, Codable {
    /// 정상적으로 잰 값이 있어요.
    case ok
    /// 아직 첫 값을 기다리는 중이에요.
    case preparing
    /// 이 Mac에는 없는 기능이에요. (예: 팬이 없는 Mac)
    case unsupported
    /// 권한이 있어야 읽을 수 있어요. (예: CPU·ANE 전력은 보조 프로그램을 허용해야 해요)
    case permissionNeeded
    /// OS가 값을 주지 않아서 잴 수 없어요. (예: ANE 사용률)
    case notMeasurable(reason: String)
    /// 센서나 기기가 꺼져 있어요. (예: ANE가 쉬는 동안의 ANE 온도)
    case off
    /// 읽기에 실패했어요.
    case failed(message: String)
    /// 전에 잰 값은 있지만 새 값이 제때 오지 않았어요. 값은 흐리게, 'N초 전 값'과 함께 보여줘요.
    /// age는 그 값을 잰 뒤 지난 시간(초)이에요. 출처가 따로 값을 내는 경우에 생겨요.
    /// (예: 보조 프로그램의 전력 표본, 배터리가 약 1분마다 알려 주는 값, 30분마다 읽는 성능 상태)
    case stale(age: Int)
}

/// 화면에 보여줄 값 하나예요. 숫자와 함께 상태와 측정 시각을 가지고 다녀요.
nonisolated struct Reading<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    var value: Value?
    var state: ValueState
    /// 이 값을 잰 시각
    var measuredAt: Date?

    init(value: Value?, state: ValueState, measuredAt: Date?) {
        self.value = value
        self.state = state
        self.measuredAt = measuredAt
    }

    /// 정상 상태일 때만 값을 돌려줘요. 다른 상태에서는 숫자를 보여주면 안 돼요.
    var okValue: Value? {
        state == .ok ? value : nil
    }

    static func ok(_ value: Value, at date: Date) -> Reading {
        Reading(value: value, state: .ok, measuredAt: date)
    }

    static var preparing: Reading {
        Reading(value: nil, state: .preparing, measuredAt: nil)
    }

    static var unsupported: Reading {
        Reading(value: nil, state: .unsupported, measuredAt: nil)
    }

    static var permissionNeeded: Reading {
        Reading(value: nil, state: .permissionNeeded, measuredAt: nil)
    }

    static var off: Reading {
        Reading(value: nil, state: .off, measuredAt: nil)
    }

    static func notMeasurable(_ reason: String) -> Reading {
        Reading(value: nil, state: .notMeasurable(reason: reason), measuredAt: nil)
    }

    static func failed(_ message: String) -> Reading {
        Reading(value: nil, state: .failed(message: message), measuredAt: nil)
    }

    /// 측정 시각이 limit초보다 오래됐으면 '오래됨'으로, 아니면 '정상'으로 바꿔요. 값은 그대로 둬요.
    /// 정상·오래됨이 아닌 값(준비 중·실패 등)은 바꾸지 않아요.
    /// (설계 문서 2장: 갱신이 멈춘 값을 지금 값처럼 보여주지 않아요)
    func checkedFreshness(now: Date, limit: TimeInterval) -> Reading {
        guard let value, let measuredAt else { return self }
        switch state {
        case .ok, .stale:
            let age = now.timeIntervalSince(measuredAt)
            guard age.isFinite, age > limit else {
                return Reading(value: value, state: .ok, measuredAt: measuredAt)
            }
            // Int(Double)는 너무 큰 값을 받으면 앱을 멈추게 해서 미리 줄여요.
            return Reading(value: value, state: .stale(age: Int(min(age, 1e9))), measuredAt: measuredAt)
        default:
            return self
        }
    }
}
