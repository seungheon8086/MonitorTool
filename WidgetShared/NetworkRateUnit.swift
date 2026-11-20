import Foundation

/// 네트워크 속도를 보여줄 단위예요. 설정 창 '일반 > 단위'에서 고르고, 패널과 위젯이 함께 써요. (2026-11-20 사용자 결정)
/// 누적량(오늘 누적 17 GB 등)은 단위와 상관없이 늘 바이트예요.
nonisolated enum NetworkRateUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 바이트: B/s · KB/s · MB/s · GB/s
    case bytes
    /// 비트: bps · Kbps · Mbps · Gbps (1 Kbps = 1000 bps)
    case bits

    /// 저장값이 없을 때 쓰는 단위
    static let standard: NetworkRateUnit = .bits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bytes: "MB/s"
        case .bits: "Mbps"
        }
    }

    /// 바이트 값에 곱해서 이 단위의 값으로 바꾸는 수예요. (그래프 눈금을 이 단위에서 깔끔한 값으로 고를 때도 써요)
    var factor: Double {
        switch self {
        case .bytes: 1
        case .bits: 8
        }
    }
}
