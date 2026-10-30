import Foundation

// 팬 제어에서 앱과 관리자 권한 보조 프로그램이 함께 쓰는 값이에요. (docs/FAN_CONTROL.md)
// 앱은 요청(FanControlRequest)을 보내고, 보조 프로그램은 지금 상태(FanControlState)를 돌려줘요.
// 둘 다 JSON으로 XPC를 지나가요.

/// 팬 하나의 목표
nonisolated enum FanTarget: Codable, Hashable, Sendable {
    /// 멈춤 (SMC 목표 0)
    case stopped
    /// 이 회전수로 고정 (팬의 최소~최대 안)
    case rpm(Int)

    /// SMC `F{i}Tg`에 쓸 값
    var smcValue: Double {
        switch self {
        case .stopped: 0
        case .rpm(let value): Double(value)
        }
    }
}

/// 앱이 보조 프로그램에 보내는 요청이에요.
nonisolated struct FanControlRequest: Codable, Hashable, Sendable {
    /// 팬마다 목표 (SMC 팬 번호 순서: 0 = 왼쪽, 1 = 오른쪽). 비어 있으면 시스템 제어로 돌려 달라는 뜻이에요.
    var targets: [FanTarget]
    /// 시스템 제어로 돌아갈 시각 (벽시계). nil이면 계속 유지예요.
    var expiresAt: Date?
    /// 프리셋 이름 또는 '직접 정하기' (패널 표시용)
    var label: String

    /// 시스템 제어로 돌려 달라는 요청
    static let system = FanControlRequest(targets: [], expiresAt: nil, label: "")

    var isSystem: Bool { targets.isEmpty }
}

/// 보조 프로그램이 고정을 풀고 시스템 제어로 돌아간 이유예요. 사용자가 직접 돌린 경우는 없어요.
nonisolated enum FanReturnReason: String, Codable, Hashable, Sendable {
    case timeEnded
    case thermalPressure
    case cpuTemperature
    case gpuTemperature
    case appDisconnected
    case otherController
    case writeFailed

    /// 패널에 보일 이유 (개조식)
    var text: String {
        switch self {
        case .timeEnded: "시간 종료"
        case .thermalPressure: "열 압력 상승"
        case .cpuTemperature: "CPU 온도 \(Int(FanControlLimits.temperatureLimit)) °C 이상"
        case .gpuTemperature: "GPU 온도 \(Int(FanControlLimits.temperatureLimit)) °C 이상"
        case .appDisconnected: "앱 종료"
        case .otherController: "다른 프로그램의 제어"
        case .writeFailed: "팬 제어 실패"
        }
    }
}

/// 시스템 제어로 돌아간 일 하나
nonisolated struct FanReturnEvent: Codable, Hashable, Sendable {
    var reason: FanReturnReason
    var at: Date
}

/// 보조 프로그램이 돌려주는 지금 상태예요.
nonisolated struct FanControlState: Codable, Hashable, Sendable {
    /// 지금 맡고 있는 고정 요청. nil이면 시스템 제어예요.
    var active: FanControlRequest?
    /// 잠자는 동안이라 잠시 시스템 제어로 돌려 둔 상태인지 (깨어나면 다시 적용해요)
    var suspendedForSleep: Bool
    /// 마지막으로 스스로 시스템 제어로 돌아간 일 (다음 고정 요청 때 지워져요)
    var lastReturn: FanReturnEvent?

    static let idle = FanControlState(active: nil, suspendedForSleep: false, lastReturn: nil)
}

/// 팬 제어의 기준값이에요.
nonisolated enum FanControlLimits {
    /// CPU·GPU 최고 온도가 이 값 이상이면 시스템 제어로 돌아가요.
    static let temperatureLimit = 95.0
    /// 이보다 낮은 온도 값은 센서 꺼짐으로 보고 판단에 쓰지 않아요. (GPU 키가 9.2 °C를 줄 때가 있어요)
    static let minimumPlausibleTemperature = 20.0
    /// 고정 중 확인 간격 (초)
    static let checkInterval = 1.0
    /// 쓴 값이 이 시간 안에 반영되지 않으면 실패로 봐요 (초). 진단에서는 1초 안에 반영됐어요.
    static let confirmTimeout = 3.0
}
