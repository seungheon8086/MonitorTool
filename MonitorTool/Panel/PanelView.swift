import SwiftUI

/// 사이드 패널 안에 보이는 화면이에요.
/// 1단계에서는 앞으로 채울 항목의 자리만 보여줘요.
struct PanelView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(MonitorSection.allCases) { section in
                    PlaceholderCard(section: section)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MonitorTool")
                .font(.title2.weight(.semibold))
            Spacer()
            Text("⌃⌥M")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .help("이 단축키로 패널을 열고 닫아요")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

/// 패널에 들어갈 항목들이에요. 선언한 순서대로 화면에 보여요.
enum MonitorSection: CaseIterable, Identifiable {
    case cpu, memory, gpu, battery, network, sensors, processes

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "메모리"
        case .gpu: "GPU"
        case .battery: "배터리"
        case .network: "네트워크"
        case .sensors: "온도·팬"
        case .processes: "상위 프로세스"
        }
    }

    var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "cube.transparent"
        case .battery: "battery.100"
        case .network: "network"
        case .sensors: "thermometer"
        case .processes: "list.bullet"
        }
    }

    /// 이 항목을 실제 수치로 채우는 단계
    var plannedStep: Int {
        switch self {
        case .cpu, .memory: 2
        case .network: 3
        case .battery: 4
        case .gpu: 5
        case .processes: 6
        case .sensors: 7
        }
    }
}

/// 아직 수치가 없는 항목을 보여주는 카드
private struct PlaceholderCard: View {
    let section: MonitorSection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.headline)
                Text("\(section.plannedStep)단계에서 채워요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    PanelView()
        .frame(width: 360, height: 640)
}
