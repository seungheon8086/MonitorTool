import Foundation

/// 패널에 보이는 항목이에요. 펼치기와 색 설정도 이 단위로 해요.
nonisolated enum MonitorItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cpu, ane, gpu, memory, thermal, battery, network

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .ane: "ANE"
        case .gpu: "GPU"
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
        case .ane: .purple
        case .gpu: .orange
        case .memory: .indigo
        case .thermal: .red
        case .battery: .green
        case .network: .yellow
        }
    }

    /// 한 항목 안의 두 번째 계열을 같은 색으로 연하게 쓰는 경우의 설명이에요.
    var secondaryNote: String? {
        switch self {
        case .cpu: "E 코어는 같은 색을 연하게 써요"
        case .thermal: "팬 2는 같은 색을 연하게 써요"
        case .network: "업로드는 같은 색을 연하게 써요"
        default: nil
        }
    }
}
