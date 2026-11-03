import Foundation

/// 그래프로 그리는 값 하나예요. 최근 기록(MetricHistory)은 이 단위로 쌓여요.
nonisolated enum Metric: Hashable, Sendable {
    /// E 코어 사용률 (%)
    case cpuEfficiency
    /// P 코어 사용률 (%)
    case cpuPerformance
    /// CPU 전력 (W)
    case cpuPower
    /// GPU 사용률 (%)
    case gpuUsage
    /// GPU 전력 (W)
    case gpuPower
    /// GPU 메모리 (바이트)
    case gpuMemory
    /// ANE 전력 (W)
    case anePower
    /// ANE의 DRAM 트래픽 (바이트/초)
    case aneTraffic
    /// 쓰는 메모리 (바이트)
    case memoryUsed
    /// 기기별 DRAM 트래픽 (바이트/초)
    case traffic(TrafficGroup)
    /// CPU 최고 온도 (°C)
    case cpuTemperature
    /// GPU 최고 온도 (°C)
    case gpuTemperature
    /// 팬 회전수 (RPM). 팬 번호는 0부터예요.
    case fan(Int)
    /// 배터리 순전력 (W)
    case batteryNetPower
    /// 받는 속도 (바이트/초)
    case networkDownload
    /// 보내는 속도 (바이트/초)
    case networkUpload

    /// 패널을 숨겼을 때 가장 느린 수집 간격(초)이에요. (설계 문서 4장: 배터리 30초, 나머지는 10초 이하)
    /// 기록 사이가 이보다 훨씬 길게 비면 그 구간은 재지 못한 것으로 보고 그래프에서 선을 끊어요.
    var slowestInterval: TimeInterval {
        switch self {
        case .batteryNetPower: 30
        default: 10
        }
    }

    /// 팬 회전수 계열인지
    var isFan: Bool {
        if case .fan = self {
            return true
        }
        return false
    }
}

/// 메모리 트래픽 누적 그래프의 층이에요. 아래에서부터 이 순서로 쌓아요.
nonisolated enum TrafficGroup: Int, CaseIterable, Hashable, Sendable {
    case cpu
    case gpu
    case ane
    /// 화면·저장장치 등 나머지 기기
    case other
}
