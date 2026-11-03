import Foundation
import SwiftUI

/// 사이드 패널 안에 보이는 화면이에요. (화면 시안 '패널 · 기본 (확정)', docs/PROJECT_DESIGN.md 1·2·3장)
/// 맨 위 카드에 CPU·GPU·ANE를 3열로 두고, 그 아래로 메모리 → 온도·팬 → 배터리 → 네트워크 순서로 보여줘요.
/// 덩어리 순서와 맨 위 카드 안 열 순서는 설정 창 '모양 > 항목 순서'에서 바꿀 수 있어요. (2026-11-03 사용자 요청)
/// 카드를 누르면 바로 아래에 상세가 펼쳐지고, 여러 항목을 함께 펼칠 수 있어요.
struct PanelView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(PanelShortcut.self) private var shortcut
    @Environment(AppearanceSettings.self) private var appearance
    /// 펼친 항목이에요. 패널을 닫았다 열어도 앱이 켜져 있는 동안은 그대로예요.
    @State private var expanded: Set<MonitorItem>
    /// 아래 톱니 단추를 눌렀을 때 할 일 (설정 창 열기)
    private let openSettings: () -> Void
    /// 아래 '보조 프로그램 허용하기' 단추를 눌렀을 때 할 일
    private let allowHelper: () -> Void
    /// 팬 제어의 '프리셋 편집': 설정 창 '팬' 탭 열기
    private let openFanSettings: () -> Void

    init(initiallyExpanded: Set<MonitorItem> = [],
         openSettings: @escaping () -> Void = {},
         allowHelper: @escaping () -> Void = {},
         openFanSettings: @escaping () -> Void = {}) {
        _expanded = State(initialValue: initiallyExpanded)
        self.openSettings = openSettings
        self.allowHelper = allowHelper
        self.openFanSettings = openFanSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(takenAt: store.snapshot.takenAt, shortcutText: shortcut.displayText,
                                shortcutNeedsAttention: shortcut.needsAttention)
                    ForEach(appearance.sectionOrder) { section in
                        sectionView(section)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)

            PanelFooter(helper: store.snapshot.helper, openSettings: openSettings, allowHelper: allowHelper)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: PanelSection) -> some View {
        switch section {
        case .processor: processorSection
        case .memory: memorySection
        case .thermal: thermalSection
        case .battery: batterySection
        case .disk: diskSection
        case .network: networkSection
        }
    }

    /// 맨 위 카드와 그 아래 상세. 상세도 카드의 열 순서를 따라요.
    @ViewBuilder
    private var processorSection: some View {
        ProcessorCard(expanded: $expanded)
        ForEach(appearance.processorOrder) { item in
            if expanded.contains(item) {
                processorDetail(item)
            }
        }
    }

    @ViewBuilder
    private func processorDetail(_ item: MonitorItem) -> some View {
        switch item {
        case .cpu: CPUDetail()
        case .gpu: GPUDetail()
        case .ane: ANEDetail()
        default: EmptyView()
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
            FanControlSection(openFanSettings: openFanSettings, allowHelper: allowHelper)
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
    private var diskSection: some View {
        DiskCard(expanded: $expanded)
        if expanded.contains(.disk) {
            DiskDetail()
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

/// 패널 글자 색 설정을 화면에 적용해요. 흰색이면 어두운 모양, 검은색이면 밝은 모양으로 고정해요. (유리는 그대로)
struct PanelTextColorScheme<Content: View>: View {
    @Environment(AppearanceSettings.self) private var appearance
    @ViewBuilder let content: Content

    var body: some View {
        switch appearance.panelText {
        case .automatic:
            content
        case .white:
            content.environment(\.colorScheme, .dark)
        case .black:
            content.environment(\.colorScheme, .light)
        }
    }
}

/// 패널 맨 위: 앱 이름, 단축키, 고정 단추, 마지막 측정 시각
private struct PanelHeader: View {
    @Environment(PanelPin.self) private var pin
    let takenAt: Date?
    /// 지금 단축키 (예: fn Space, ⌃⌥M). 단축키를 껐으면 nil이에요.
    let shortcutText: String?
    /// 단축키가 켜져 있는데 지금 동작하지 않는지 (예: 손쉬운 사용 허용 전)
    let shortcutNeedsAttention: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Text("MonitorTool")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let shortcutText {
                    Text(shortcutText)
                        .font(.callout.monospaced())
                        .foregroundStyle(shortcutNeedsAttention ? StatusColor.warningText : Color.secondary)
                        .help(shortcutNeedsAttention
                              ? "단축키 작동 불가. MonitorTool 설정 > 일반에서 확인 필요"
                              : "전역 접근 단축키(fn + Space는 손쉬운 사용 허용 필요)")
                }
                pinButton
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

    /// 고정 단추: 켜면 바깥을 눌러도 패널이 닫히지 않아요.
    private var pinButton: some View {
        Button {
            pin.toggle()
        } label: {
            Image(systemName: pin.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(pin.isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .background {
                    if pin.isPinned {
                        Circle().fill(Color.accentColor.opacity(0.15))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pin.isPinned ? "고정 해제" : "고정 · 바깥 클릭에도 유지")
        .accessibilityLabel(Text(pin.isPinned ? "패널 고정 해제" : "패널 고정"))
    }
}

/// 패널 맨 아래: 보조 프로그램 허용 버튼(필요할 때만, 2026-10-23 합의)과 설정 톱니 단추
private struct PanelFooter: View {
    let helper: HelperStatus
    let openSettings: () -> Void
    /// 꺼져 있으면 켜고, 시스템 설정의 허용 화면을 열어요.
    let allowHelper: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if helper.needsUserAction {
                Button(action: allowHelper) {
                    Text("CPU·ANE 전력: 보조 프로그램 허용하기")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StatusColor.warningText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(StatusColor.warningBackground,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("설정")
            .accessibilityLabel(Text("설정"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

#if DEBUG
// Xcode 미리보기 (예시 값은 여기서만 써요. 실제 앱에는 나오지 않아요.)

#Preview("예시 값") {
    PanelView()
        .environment(MonitorStore.example)
        .environment(AppearanceSettings())
        .environment(PanelShortcut(action: {}))
        .environment(FanControlModel.preview())
        .environment(PanelPin(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .frame(width: 380, height: 900)
        .background(.regularMaterial)
}

#Preview("펼친 상태 (CPU·GPU·ANE·메모리·온도)") {
    PanelView(initiallyExpanded: [.cpu, .gpu, .ane, .memory, .thermal])
        .environment(MonitorStore.example)
        .environment(AppearanceSettings())
        .environment(PanelShortcut(action: {}))
        .environment(FanControlModel.preview())
        .environment(PanelPin(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .frame(width: 380, height: 2700)
        .background(.regularMaterial)
}

#Preview("펼친 상태 (배터리·네트워크)") {
    PanelView(initiallyExpanded: [.battery, .network])
        .environment(MonitorStore.example)
        .environment(AppearanceSettings())
        .environment(PanelShortcut(action: {}))
        .environment(FanControlModel.preview())
        .environment(PanelPin(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .frame(width: 380, height: 1300)
        .background(.regularMaterial)
}

#Preview("보조 프로그램 허용 전") {
    PanelView(initiallyExpanded: [.cpu, .ane])
        .environment(MonitorStore.exampleNeedsHelper)
        .environment(AppearanceSettings())
        .environment(PanelShortcut(action: {}))
        .environment(FanControlModel.preview())
        .environment(PanelPin(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .frame(width: 380, height: 1500)
        .background(.regularMaterial)
}

#Preview("오래된 값 (CPU·ANE 전력, 배터리)") {
    PanelView(initiallyExpanded: [.battery])
        .environment(MonitorStore.exampleStale)
        .environment(AppearanceSettings())
        .environment(PanelShortcut(action: {}))
        .environment(FanControlModel.preview())
        .environment(PanelPin(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .frame(width: 380, height: 1300)
        .background(.regularMaterial)
}

#Preview("수집 전 (지금 앱 실행 화면)") {
    PanelView()
        .environment(MonitorStore())
        .environment(AppearanceSettings())
        .environment(PanelShortcut(action: {}))
        .environment(FanControlModel.preview())
        .environment(PanelPin(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .frame(width: 380, height: 900)
        .background(.regularMaterial)
}
#endif
