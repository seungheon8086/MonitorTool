import SwiftUI

/// 패널 맨 위 카드예요. CPU·GPU·ANE를 한 칸에 왼쪽부터 3열로 보여줘요.
/// (화면 시안 '패널 · 기본 (확정)'에서 순서만 CPU·GPU·ANE로 바꿨어요. 2026-10-24 사용자 결정)
/// 열을 누르면 카드 아래로 그 항목의 상세가 펼쳐져요.
struct ProcessorCard: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @Binding var expanded: Set<MonitorItem>

    var body: some View {
        let snapshot = store.snapshot
        HStack(spacing: 0) {
            column(.cpu, shape: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                                       style: .continuous)) {
                CPUColumn(cpu: snapshot.cpu, color: appearance.color(for: .cpu))
            }
            ColumnDivider()
            column(.gpu, shape: Rectangle()) {
                GPUColumn(gpu: snapshot.gpu, color: appearance.color(for: .gpu))
            }
            ColumnDivider()
            column(.ane, shape: UnevenRoundedRectangle(bottomTrailingRadius: 14, topTrailingRadius: 14,
                                                       style: .continuous)) {
                ANEColumn(ane: snapshot.ane)
            }
        }
        // 세 열의 높이를 맞춰서 맨 아래 '전력' 줄이 같은 높이에 오게 해요.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 열 하나를 누를 수 있는 버튼으로 만들어요. 펼친 열은 강조색으로 칠해요.
    private func column<S: Shape, Content: View>(_ item: MonitorItem,
                                                  shape: S,
                                                  @ViewBuilder content: () -> Content) -> some View {
        let isExpanded = expanded.contains(item)
        let hint: LocalizedStringKey = isExpanded ? "눌러서 접어요" : "눌러서 자세히 봐요"
        return Button {
            withAnimation(PanelMotion.expand) {
                if isExpanded {
                    expanded.remove(item)
                } else {
                    expanded.insert(item)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    ExpandChevron(isExpanded: isExpanded)
                }
                content()
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 10))
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .background {
                if isExpanded {
                    shape.fill(Color.accentColor.opacity(0.10))
                }
            }
            .overlay {
                if isExpanded {
                    shape.stroke(Color.accentColor.opacity(0.30), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }
}

/// 열 사이의 가는 세로줄
private struct ColumnDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1)
            .padding(.vertical, 10)
    }
}

/// CPU 열: E·P 코어 사용률과 전력
private struct CPUColumn: View {
    let cpu: CPUSnapshot
    let color: ItemColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageLine(label: "E", reading: cpu.efficiencyUsage, color: color.secondaryColor)
            UsageLine(label: "P", reading: cpu.performanceUsage, color: color.color)
            Spacer(minLength: 0)
            PowerLine(reading: cpu.power)
        }
    }
}

/// GPU 열: 사용률과 전력
private struct GPUColumn: View {
    let gpu: GPUSnapshot
    let color: ItemColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageLine(label: "사용률", reading: gpu.usage, color: color.color)
            Spacer(minLength: 0)
            PowerLine(reading: gpu.power)
        }
    }
}

/// ANE 열: 사용 중 여부와 전력. 사용률은 잴 수 없어서 이유를 적어 둬요.
private struct ANEColumn: View {
    let ane: ANESnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ANEActivityLabel(reading: ane.isActive)
            Text("사용률은\n측정 불가")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PowerLine(reading: ane.power)
        }
    }
}

/// 이름과 % 값 한 줄, 그 아래 얇은 막대
private struct UsageLine: View {
    let label: String
    let reading: Reading<Double>
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ValueText(reading: reading, format: ValueFormat.percent)
            }
            UsageBar(fraction: reading.okValue.map { $0 / 100 }, color: color, height: 4)
        }
    }
}

/// 열 맨 아래의 '전력 2.3 W' 줄
private struct PowerLine: View {
    let reading: Reading<Double>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("전력")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            ValueText(reading: reading, format: ValueFormat.watts, font: .system(size: 13, weight: .semibold))
        }
        .padding(.top, 7)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }
}

/// ANE '사용 중 / 쉬는 중' 표시예요. 상세 화면에서도 써요.
struct ANEActivityLabel: View {
    let reading: Reading<Bool>
    var font: Font = .system(size: 15, weight: .semibold)

    var body: some View {
        if let isActive = reading.okValue {
            HStack(spacing: 5) {
                if isActive {
                    Circle()
                        .fill(StatusColor.active)
                        .frame(width: 8, height: 8)
                    Text("사용 중")
                        .font(font)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                    Text("쉬는 중")
                        .font(font)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        } else {
            StateText(state: reading.state)
        }
    }
}
