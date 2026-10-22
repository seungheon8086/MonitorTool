import SwiftUI

/// 사이드 패널 안에 보이는 화면이에요.
/// 아직 기술 검증 전이라, 항목의 자리와 접힌 상태에서 보여줄 내용만 표시해요.
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("MonitorTool")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("⌃⌥M")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .help("이 단축키로 패널을 열고 닫아요")
            }
            Text("수치는 기술 검증을 마친 뒤 채워요")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

/// 패널에 들어갈 항목이에요. 선언한 순서대로 보여요. (docs/PROJECT_DESIGN.md 2·3장)
enum MonitorSection: CaseIterable, Identifiable {
    case cpu, ane, gpu, memory, thermal, battery, network

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .ane: "ANE"
        case .gpu: "GPU"
        case .memory: "RAM"
        case .thermal: "온도·팬"
        case .battery: "배터리"
        case .network: "네트워크"
        }
    }

    var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .ane: "brain"
        case .gpu: "cube.transparent"
        case .memory: "memorychip"
        case .thermal: "fan"
        case .battery: "battery.100"
        case .network: "network"
        }
    }

    /// 접힌 상태에서 보여줄 수치 (설계 문서 3장 표의 '접힌 상태')
    var summary: String {
        switch self {
        case .cpu: "E·P 코어 사용률 · CPU 전력"
        case .ane: "사용률 % · 전력 W"
        case .gpu: "사용률 · 전력 W"
        case .memory: "사용량 · 사용률"
        case .thermal: "CPU·GPU 최고 온도 · 팬별 RPM"
        case .battery: "잔량 · 상태 · 순전력 W · 예상 시간"
        case .network: "업·다운 속도 · 오늘 누적"
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
                Text(section.summary)
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
        .frame(width: 380, height: 640)
}
