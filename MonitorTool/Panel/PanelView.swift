import SwiftUI

/// 사이드 패널 안에 보이는 화면이에요. (화면 시안 '패널 · 기본 (확정)', docs/PROJECT_DESIGN.md 1·2·3장)
/// 맨 위 카드에 CPU·GPU·ANE를 3열로 두고, 그 아래로 메모리 → 온도·팬 → 배터리 → 네트워크 순서로 보여줘요.
/// 카드를 누르면 바로 아래에 상세가 펼쳐지고, 여러 항목을 함께 펼칠 수 있어요.
struct PanelView: View {
    @Environment(MonitorStore.self) private var store
    /// 펼친 항목이에요. 패널을 닫았다 열어도 앱이 켜져 있는 동안은 그대로예요.
    @State private var expanded: Set<MonitorItem>

    init(initiallyExpanded: Set<MonitorItem> = []) {
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(takenAt: store.snapshot.takenAt)
                    processorSection
                    memorySection
                    thermalSection
                    batterySection
                    networkSection
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)

            PanelFooter(helper: store.snapshot.helper)
        }
    }

    @ViewBuilder
    private var processorSection: some View {
        ProcessorCard(expanded: $expanded)
        if expanded.contains(.cpu) {
            CPUDetail()
        }
        if expanded.contains(.gpu) {
            GPUDetail()
        }
        if expanded.contains(.ane) {
            ANEDetail()
        }
    }

    @ViewBuilder
    private var memorySection: some View {
        MemoryCard(expanded: $expanded)
        if expanded.contains(.memory) {
            MemoryDetail()
        }
    }

    @ViewBuilder
    private var thermalSection: some View {
        ThermalCard(expanded: $expanded)
        if expanded.contains(.thermal) {
            ThermalDetail()
        }
    }

    @ViewBuilder
    private var batterySection: some View {
        BatteryCard(expanded: $expanded)
        if expanded.contains(.battery) {
            BatteryDetail()
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        NetworkCard(expanded: $expanded)
        if expanded.contains(.network) {
            NetworkDetail()
        }
    }
}

/// 패널 맨 위: 앱 이름, 단축키, 마지막 측정 시각
private struct PanelHeader: View {
    let takenAt: Date?

    var body: some View {
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
            if let takenAt {
                Text("\(ValueFormat.clock(takenAt)) 측정 · 1초마다 갱신")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("측정 준비 중")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

/// 패널 맨 아래: 보조 프로그램을 허용해야 할 때만 버튼을 보여줘요. (2026-10-23 합의)
private struct PanelFooter: View {
    let helper: HelperStatus

    var body: some View {
        if helper.needsUserAction {
            HStack {
                Button {
                    // 보조 프로그램 등록과 시스템 설정 열기는 5단계(통합)에서 연결해요.
                } label: {
                    Text("CPU·ANE 전력: 보조 프로그램 허용하기")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StatusColor.warningText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(StatusColor.warningBackground,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
    }
}

#if DEBUG
// Xcode 미리보기 (예시 값은 여기서만 써요. 실제 앱에는 나오지 않아요.)

#Preview("예시 값") {
    PanelView()
        .environment(MonitorStore.example)
        .environment(AppearanceSettings())
        .frame(width: 380, height: 900)
        .background(.regularMaterial)
}

#Preview("펼친 상태 (CPU·GPU·ANE·메모리·온도)") {
    PanelView(initiallyExpanded: [.cpu, .gpu, .ane, .memory, .thermal])
        .environment(MonitorStore.example)
        .environment(AppearanceSettings())
        .frame(width: 380, height: 2700)
        .background(.regularMaterial)
}

#Preview("펼친 상태 (배터리·네트워크)") {
    PanelView(initiallyExpanded: [.battery, .network])
        .environment(MonitorStore.example)
        .environment(AppearanceSettings())
        .frame(width: 380, height: 1300)
        .background(.regularMaterial)
}

#Preview("보조 프로그램 허용 전") {
    PanelView(initiallyExpanded: [.cpu, .ane])
        .environment(MonitorStore.exampleNeedsHelper)
        .environment(AppearanceSettings())
        .frame(width: 380, height: 1500)
        .background(.regularMaterial)
}

#Preview("수집 전 (지금 앱 실행 화면)") {
    PanelView()
        .environment(MonitorStore())
        .environment(AppearanceSettings())
        .frame(width: 380, height: 900)
        .background(.regularMaterial)
}
#endif
