import SwiftUI

// CPU·GPU·ANE 열을 눌렀을 때 카드 아래로 펼쳐지는 상세예요. (화면과 같은 순서로 놓았어요)
// 그래프 기간(1분·5분·30분)은 카드마다 따로 고르고, 고른 기간은 앱을 다시 켜도 남아요.

struct CPUDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("chartPeriod.cpu") private var period: ChartPeriod = .oneMinute

    private var cpu: CPUSnapshot { store.snapshot.cpu }
    private var color: ItemColor { appearance.color(for: .cpu) }

    var body: some View {
        DetailCard(title: "CPU 자세히") {
            PeriodPicker(period: $period)
        } content: {
            usageChart
            powerChart
            coreSection
        }
    }

    /// E·P 코어 사용률 그래프 (E는 연한 색)
    private var usageChart: some View {
        HistoryChart(title: "사용률",
                     lines: [ChartLine(metric: .cpuEfficiency, label: "E", color: color.secondaryColor),
                             ChartLine(metric: .cpuPerformance, label: "P", color: color.color)],
                     period: period,
                     scale: .percent,
                     height: 90,
                     emptyState: cpu.performanceUsage.state,
                     scaleText: ValueFormat.percent) {
            HStack(spacing: 10) {
                LegendValue(color: color.secondaryColor, label: "E",
                            reading: cpu.efficiencyUsage, format: ValueFormat.percent)
                LegendValue(color: color.color, label: "P",
                            reading: cpu.performanceUsage, format: ValueFormat.percent)
            }
        }
    }

    /// CPU 전력 그래프 ('2.3 W · 1분 평균 2.1 W')
    private var powerChart: some View {
        HistoryChart(title: "전력",
                     lines: [ChartLine(metric: .cpuPower, label: "전력", color: color.color)],
                     period: period,
                     scale: .automatic(minimum: 1),
                     emptyState: cpu.power.state,
                     scaleText: ValueFormat.wattsScale) {
            ValueWithAverage(reading: cpu.power, metric: .cpuPower, period: period, format: ValueFormat.watts)
        }
    }

    private var coreSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("코어별 사용률")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if cpu.cores.isEmpty {
                StateText(state: .preparing)
            } else {
                CoreBars(groups: cpu.coreGroups, color: color)
            }
        }
    }
}

/// 코어별 사용률 막대. 묶음(E, P 묶음 1, P 묶음 2)별로 모아서 보여줘요.
struct CoreBars: View {
    let groups: [CoreGroup]
    let color: ItemColor

    private static let barHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(groups) { group in
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(group.cores) { core in
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                                .fill(group.kind == .efficiency ? color.secondaryColor : color.color)
                                .frame(width: 14, height: max(2, Self.barHeight * min(core.usage, 100) / 100))
                                .help(Text("CPU \(core.id) · \(ValueFormat.percent(core.usage))"))
                        }
                    }
                    .frame(height: Self.barHeight, alignment: .bottom)
                    Text(group.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("코어별 사용률"))
    }
}

struct GPUDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("chartPeriod.gpu") private var period: ChartPeriod = .oneMinute

    private var gpu: GPUSnapshot { store.snapshot.gpu }
    private var color: ItemColor { appearance.color(for: .gpu) }

    var body: some View {
        DetailCard(title: "GPU 자세히") {
            PeriodPicker(period: $period)
        } content: {
            usageChart
            powerChart
        }
    }

    private var usageChart: some View {
        HistoryChart(title: "사용률",
                     lines: [ChartLine(metric: .gpuUsage, label: "사용률", color: color.color)],
                     period: period,
                     scale: .percent,
                     height: 72,
                     emptyState: gpu.usage.state,
                     scaleText: ValueFormat.percent) {
            ValueText(reading: gpu.usage, format: ValueFormat.percent, font: .system(size: 12))
        }
    }

    /// GPU 전력 그래프 ('0.4 W · 1분 평균 0.5 W')
    private var powerChart: some View {
        HistoryChart(title: "전력",
                     lines: [ChartLine(metric: .gpuPower, label: "전력", color: color.color)],
                     period: period,
                     scale: .automatic(minimum: 1),
                     emptyState: gpu.power.state,
                     scaleText: ValueFormat.wattsScale) {
            ValueWithAverage(reading: gpu.power, metric: .gpuPower, period: period, format: ValueFormat.watts)
        }
    }
}

struct ANEDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("chartPeriod.ane") private var period: ChartPeriod = .oneMinute

    private var ane: ANESnapshot { store.snapshot.ane }
    private var color: ItemColor { appearance.color(for: .ane) }

    var body: some View {
        DetailCard(title: "ANE (Neural Engine) 자세히") {
            PeriodPicker(period: $period)
        } content: {
            summaryRow
            powerChart
            trafficChart
        }
    }

    /// 상태 · 전력 · ANE 온도 (사용 중이면 상태 아래에 켜진 시각)
    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("상태")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ANEActivityLabel(reading: ane.isActive)
                if let since = activeSinceText {
                    Text(since)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LabeledValue(label: "전력", reading: ane.power, format: ValueFormat.watts)
            LabeledValue(label: "ANE 온도", reading: ane.temperature, format: ValueFormat.celsius)
        }
    }

    private var powerChart: some View {
        HistoryChart(title: "전력",
                     lines: [ChartLine(metric: .anePower, label: "전력", color: color.color)],
                     period: period,
                     scale: .automatic(minimum: 1),
                     emptyState: ane.power.state,
                     scaleText: ValueFormat.wattsScale) {
            ValueText(reading: ane.power, format: ValueFormat.watts, font: .system(size: 12))
        }
    }

    private var trafficChart: some View {
        HistoryChart(title: "ANE의 DRAM 트래픽",
                     lines: [ChartLine(metric: .aneTraffic, label: "트래픽", color: color.color)],
                     period: period,
                     scale: .automatic(minimum: 1_000_000_000),
                     emptyState: ane.dramTraffic.state,
                     scaleText: ValueFormat.gigabytesPerSecondScale) {
            ValueText(reading: ane.dramTraffic, format: ValueFormat.gigabytesPerSecond, font: .system(size: 12))
        }
    }

    /// '18:45:48부터' (사용 중일 때만)
    private var activeSinceText: String? {
        guard ane.isActive.okValue == true, let since = ane.activeSince else { return nil }
        return "\(ValueFormat.clock(since))부터"
    }
}
