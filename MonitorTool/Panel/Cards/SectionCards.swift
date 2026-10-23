import Foundation
import SwiftUI

/// 한 줄 카드(메모리·온도·팬·배터리·네트워크)의 공통 틀이에요. 누르면 펼치고 접어요.
struct SectionCard<Accessory: View, Content: View>: View {
    let item: MonitorItem
    /// 펼친 항목 목록 (패널 전체가 함께 써요)
    @Binding var expanded: Set<MonitorItem>
    /// 제목 오른쪽에 붙는 작은 정보 (예: '압력 정상')
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    private var isExpanded: Bool {
        expanded.contains(item)
    }

    var body: some View {
        Button {
            withAnimation(PanelMotion.expand) {
                if expanded.contains(item) {
                    expanded.remove(item)
                } else {
                    expanded.insert(item)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    accessory
                    ExpandChevron(isExpanded: isExpanded)
                }
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(CardBackground(isExpanded: isExpanded))
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    private var hint: LocalizedStringKey {
        isExpanded ? "눌러서 접어요" : "눌러서 자세히 봐요"
    }
}

// MARK: - 메모리

struct MemoryCard: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @Binding var expanded: Set<MonitorItem>

    var body: some View {
        let memory = store.snapshot.memory
        SectionCard(item: .memory, expanded: $expanded) {
            PressureLabel(reading: memory.pressure)
        } content: {
            HStack(spacing: 8) {
                MemoryAmountText(used: memory.used, total: memory.total)
                UsageBar(fraction: memory.usagePercent.okValue.map { $0 / 100 },
                         color: appearance.color(for: .memory).color)
                ValueText(reading: memory.usagePercent, format: ValueFormat.percent)
                    .frame(minWidth: 42, alignment: .trailing)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("DRAM 트래픽")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ValueText(reading: memory.trafficTotal, format: ValueFormat.gigabytesPerSecond)
            }
            ProcessorTrafficChips(memory: memory)
        }
    }
}

/// 메모리 압력 표시 (점 + 글)
struct PressureLabel: View {
    let reading: Reading<MemoryPressure>

    var body: some View {
        if let pressure = reading.okValue {
            HStack(spacing: 4) {
                Circle()
                    .fill(color(for: pressure))
                    .frame(width: 7, height: 7)
                Text(title(for: pressure))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            StateText(state: reading.state)
        }
    }

    private func title(for pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "압력 정상"
        case .warning: "압력 주의"
        case .critical: "압력 높음"
        }
    }

    private func color(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: StatusColor.active
        case .warning: Color.yellow
        case .critical: StatusColor.error
        }
    }
}

/// '11.4 / 16 GB'
struct MemoryAmountText: View {
    let used: Reading<Double>
    let total: Reading<Double>
    var font: Font = .system(size: 15, weight: .semibold)

    var body: some View {
        if let usedBytes = used.okValue, let totalBytes = total.okValue {
            Text("\(ValueFormat.memoryNumber(usedBytes)) / \(ValueFormat.memoryNumber(totalBytes)) GB")
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        } else {
            StateText(state: used.state == .ok ? total.state : used.state)
        }
    }
}

/// CPU·GPU·ANE의 DRAM 트래픽을 각 항목 색으로 보여줘요. (기본 화면에 기기별까지, 2026-10-23 사용자 선택)
struct ProcessorTrafficChips: View {
    let memory: MemorySnapshot
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        if memory.trafficTotal.okValue != nil {
            HStack(spacing: 12) {
                chip(.cpu, item: .cpu, label: "CPU")
                chip(.gpu, item: .gpu, label: "GPU")
                chip(.ane, item: .ane, label: "ANE")
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func chip(_ device: TrafficDevice, item: MonitorItem, label: String) -> some View {
        if let bytes = memory.traffic(of: device) {
            ColorChip(color: appearance.color(for: item).color,
                      text: "\(label) \(ValueFormat.gigabytesPerSecondNumber(bytes))")
        }
    }
}

// MARK: - 온도·팬

struct ThermalCard: View {
    @Environment(MonitorStore.self) private var store
    @Binding var expanded: Set<MonitorItem>

    private var columns: [GridItem] {
        [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    }

    var body: some View {
        let thermal = store.snapshot.thermal
        SectionCard(item: .thermal, expanded: $expanded) {
            EmptyView()
        } content: {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                LabeledValue(label: "CPU 최고", reading: thermal.cpuMax, format: ValueFormat.celsius)
                LabeledValue(label: "GPU 최고", reading: thermal.gpuMax, format: ValueFormat.celsius)
                if let fans = thermal.fans.okValue {
                    ForEach(fans) { fan in
                        FanValue(fan: fan)
                    }
                } else {
                    LabeledValue(label: "팬",
                                 reading: Reading<Double>(value: nil, state: thermal.fans.state, measuredAt: nil),
                                 format: ValueFormat.rpm)
                }
            }
        }
    }
}

/// 팬 하나의 회전수. 읽기에 성공한 0 RPM은 '정지'로 보여줘요.
struct FanValue: View {
    let fan: FanReading

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("팬 \(fan.id + 1)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let rpm = fan.rpm.okValue {
                if rpm < 1 {
                    Text("정지")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(ValueFormat.rpm(rpm))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                }
            } else {
                StateText(state: fan.rpm.state)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 배터리

struct BatteryCard: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @Binding var expanded: Set<MonitorItem>

    var body: some View {
        let battery = store.snapshot.battery
        SectionCard(item: .battery, expanded: $expanded) {
            Text(BatteryText.status(battery))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } content: {
            HStack(spacing: 8) {
                ValueText(reading: battery.level, format: ValueFormat.percent)
                    .frame(minWidth: 42, alignment: .leading)
                UsageBar(fraction: battery.level.okValue.map { $0 / 100 },
                         color: appearance.color(for: .battery).color)
                ValueText(reading: battery.netPower, format: ValueFormat.signedWatts)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }
}

/// 배터리 상태를 한 줄 글로 만들어요. (예: '방전 중 · 4시간 20분 남음')
enum BatteryText {
    static func status(_ battery: BatterySnapshot) -> String {
        guard let chargeState = battery.chargeState.okValue else {
            switch battery.chargeState.state {
            case .unsupported: return "배터리 없음"
            case .preparing: return "준비 중"
            default: return ""
            }
        }
        let time = battery.timeRemaining.okValue
        switch chargeState {
        case .charging:
            if let time { return "충전 중 · 완충까지 \(ValueFormat.duration(time))" }
            return "충전 중"
        case .discharging:
            if let time { return "방전 중 · \(ValueFormat.duration(time)) 남음" }
            return "방전 중"
        case .charged:
            return "완충"
        case .onHold:
            return "충전 보류"
        }
    }
}

// MARK: - 네트워크

struct NetworkCard: View {
    @Environment(MonitorStore.self) private var store
    @Binding var expanded: Set<MonitorItem>

    var body: some View {
        let network = store.snapshot.network
        SectionCard(item: .network, expanded: $expanded) {
            EmptyView()
        } content: {
            HStack(alignment: .top, spacing: 8) {
                LabeledValue(label: "↓ 다운로드", reading: network.download, format: ValueFormat.rate)
                LabeledValue(label: "↑ 업로드", reading: network.upload, format: ValueFormat.rate)
            }
            if let downloaded = network.todayDownloaded.okValue, let uploaded = network.todayUploaded.okValue {
                Text("오늘 누적 ↓ \(ValueFormat.byteCount(downloaded)) · ↑ \(ValueFormat.byteCount(uploaded))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
