import SwiftUI
import WidgetKit

/// 그래프만 띄우는 작은 위젯이에요. 항목마다 따로 있어서 알림 센터에서 골라 써요. (docs/WIDGET_V2.md 2장)
enum GraphItem: String, CaseIterable {
    case usage, power, temperature, fan, network, battery

    var kind: String {
        "MonitorToolGraph.\(rawValue)"
    }

    var displayName: String {
        switch self {
        case .usage: "MonitorTool CPU·GPU 사용률"
        case .power: "MonitorTool 전력"
        case .temperature: "MonitorTool 온도"
        case .fan: "MonitorTool 팬"
        case .network: "MonitorTool 네트워크"
        case .battery: "MonitorTool 배터리 순전력"
        }
    }

    /// 그래프 카드 내용 (큰 위젯에 쓰려고 만들어 둔 WidgetGraphs를 그대로 써요)
    func card(_ payload: WidgetPayload) -> WidgetGraphCard {
        let colors = WidgetColors(payload: payload)
        switch self {
        case .usage: return WidgetGraphs.usage(payload, colors)
        case .power: return WidgetGraphs.power(payload, colors)
        case .temperature: return WidgetGraphs.temperature(payload, colors)
        case .fan: return WidgetGraphs.fan(payload, colors)
        case .network: return WidgetGraphs.network(payload, colors)
        case .battery: return WidgetGraphs.battery(payload, colors)
        }
    }

    /// 값이 없을 때 제목
    var title: String {
        switch self {
        case .usage: "CPU·GPU 사용률"
        case .power: "전력"
        case .temperature: "온도"
        case .fan: "팬"
        case .network: "네트워크"
        case .battery: "배터리 순전력"
        }
    }
}

struct UsageGraphWidget: Widget {
    var body: some WidgetConfiguration { GraphWidgetConfiguration.make(.usage) }
}

struct PowerGraphWidget: Widget {
    var body: some WidgetConfiguration { GraphWidgetConfiguration.make(.power) }
}

struct TemperatureGraphWidget: Widget {
    var body: some WidgetConfiguration { GraphWidgetConfiguration.make(.temperature) }
}

struct NetworkGraphWidget: Widget {
    var body: some WidgetConfiguration { GraphWidgetConfiguration.make(.network) }
}

struct FanGraphWidget: Widget {
    var body: some WidgetConfiguration { GraphWidgetConfiguration.make(.fan) }
}

struct BatteryGraphWidget: Widget {
    var body: some WidgetConfiguration { GraphWidgetConfiguration.make(.battery) }
}

enum GraphWidgetConfiguration {
    static func make(_ item: GraphItem) -> some WidgetConfiguration {
        StaticConfiguration(kind: item.kind, provider: MonitorProvider()) { entry in
            SmallGraphView(item: item, entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(item.displayName)
        .description("최근 10분 그래프")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}

/// 작은 그래프 위젯 한 장: 제목 · 지금 값 · 꺾은선 · 측정 시각
struct SmallGraphView: View {
    let item: GraphItem
    let entry: MonitorEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let payload = entry.payload {
                let card = item.card(payload)
                header(card.title)
                VStack(alignment: .leading, spacing: 5) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(card.legends) { legend in
                            legendRow(legend)
                        }
                    }
                    WidgetSparkline(lines: card.lines, fixedMaximum: card.fixedMaximum,
                                    minimumMaximum: card.minimumMaximum, symmetric: card.symmetric,
                                    axisFormat: card.axisFormat)
                        .frame(maxHeight: .infinity)
                    footer(payload)
                }
                .opacity(entry.status.dims ? 0.45 : 1)
            } else {
                header(item.title)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text("10분")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let badge = entry.status.badge {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WidgetStatusColor.warningText)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(WidgetStatusColor.warningBackground,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// '▬ P ⋯ 34%'
    private func legendRow(_ legend: WidgetGraphCard.Legend) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 2))
                path.addLine(to: CGPoint(x: 10, y: 2))
            }
            .stroke(legend.color, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                     dash: legend.dashed ? [3, 2] : []))
            .frame(width: 10, height: 4)
            Text(legend.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(legend.value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func footer(_ payload: WidgetPayload) -> some View {
        HStack {
            Spacer(minLength: 0)
            if let takenAt = payload.snapshot.takenAt {
                Text(ValueFormat.clock(takenAt))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
