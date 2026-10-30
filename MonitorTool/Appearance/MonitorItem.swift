import Foundation

/// 패널에 보이는 항목이에요. 펼치기와 색 설정도 이 단위로 해요.
/// 순서는 패널과 설정 창에 보이는 순서예요. (맨 위 카드는 CPU·GPU·ANE, 2026-10-24 사용자 결정)
nonisolated enum MonitorItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cpu, gpu, ane, memory, thermal, battery, network

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ane: "ANE"
        case .memory: "메모리"
        case .thermal: "온도·팬"
        case .battery: "배터리"
        case .network: "네트워크"
        }
    }

    /// 처음 쓸 때의 색 (설계 문서 1장, 2026-10-23 합의)
    var defaultColor: ItemColor {
        switch self {
        case .cpu: .blue
        case .gpu: .orange
        case .ane: .purple
        case .memory: .indigo
        case .thermal: .red
        case .battery: .green
        case .network: .yellow
        }
    }

    /// 한 항목 안의 두 번째 계열을 같은 색으로 연하게 쓰는 경우의 설명이에요.
    var secondaryNote: String? {
        switch self {
        case .cpu: "P-core : 진하게, E-core : 연하게"
        case .thermal: "Fan1 : 진하게, Fan2 : 연하게"
        case .network: "up : 연하게, down : 진하게"
        default: nil
        }
    }
}
