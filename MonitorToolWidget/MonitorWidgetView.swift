import SwiftUI
import WidgetKit

/// 위젯 한 장이에요. 맨 위 줄 + 크기에 맞는 요약. (docs/WIDGET_V2.md 2장)
struct MonitorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MonitorEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(entry: entry)
            if let payload = entry.payload {
                content(payload: payload)
                    // 오래됨·잠자기·앱 꺼짐이면 지금 값처럼 보이지 않게 흐리게 (패널의 오래된 값과 같은 45%)
                    .opacity(entry.status.dims ? 0.45 : 1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(payload: WidgetPayload) -> some View {
        let colors = WidgetColors(payload: payload)
        if family == .systemLarge {
            LargeSummary(snapshot: payload.snapshot, colors: colors)
        } else {
            MediumSummary(snapshot: payload.snapshot, colors: colors)
        }
    }
}

/// 공유 파일의 항목 색. 읽지 못한 항목은 기본 색이에요.
struct WidgetColors {
    let payload: WidgetPayload

    func callAsFunction(_ item: MonitorItem) -> ItemColor {
        payload.colors[item.rawValue].flatMap(ItemColor.init(rawValue:)) ?? item.defaultColor
    }
}

// MARK: - 맨 위 줄

/// 'MonitorTool · 18:42:05 · [오래됨]'
struct WidgetHeader: View {
    let entry: MonitorEntry

    var body: some View {
        HStack(spacing: 6) {
            Text("MonitorTool")
                .font(.system(size: 11, weight: .semibold))
            if let takenAt = entry.payload?.snapshot.takenAt {
                Text(ValueFormat.clock(takenAt))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let badge = entry.status.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WidgetStatusColor.warningText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(WidgetStatusColor.warningBackground,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

// MARK: - 요약

/// 패널 맨 위 카드와 같은 CPU·GPU·ANE 3열 카드
struct WidgetProcessorCard: View {
    let snapshot: MonitorSnapshot
    let colors: WidgetColors
    /// 중간 크기에서는 글자와 간격을 한 단계 줄여요. (높이가 약 80 pt뿐이에요)
    var compact = false

    private var valueFont: Font {
        .system(size: compact ? 11 : 12, weight: .semibold)
    }

    var body: some View {
        HStack(spacing: 0) {
            column("CPU", power: snapshot.cpu.power) {
                usageLine("E", snapshot.cpu.efficiencyUsage, colors(.cpu).secondaryColor)
                usageLine("P", snapshot.cpu.performanceUsage, colors(.cpu).color)
            }
            divider
            column("GPU", power: snapshot.gpu.power) {
                usageLine("사용률", snapshot.gpu.usage, colors(.gpu).color)
            }
            divider
            column("ANE", power: snapshot.ane.power) {
                WidgetANEActivity(reading: snapshot.ane.isActive)
                Text("사용률 측정 불가")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.045), in: ContainerRelativeShape())
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1)
            .padding(.vertical, 8)
    }

    private func column<Content: View>(_ title: String, power: Reading<Double>,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text(title)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .lineLimit(1)
            content()
            Spacer(minLength: 0)
            WidgetValueRow(label: "전력", reading: power, format: ValueFormat.watts, font: valueFont)
                .modifier(WidgetTopRule())
        }
        .padding(compact ? EdgeInsets(top: 5, leading: 8, bottom: 4, trailing: 7)
                         : EdgeInsets(top: 7, leading: 9, bottom: 6, trailing: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func usageLine(_ label: String, _ reading: Reading<Double>, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                WidgetValueText(reading: reading, format: ValueFormat.percent, font: valueFont)
            }
            WidgetUsageBar(fraction: reading.okValue.map { $0 / 100 }, color: color, height: 3)
        }
    }
}

/// 중간 크기 요약: 3열 카드 + 한 줄 칩
struct MediumSummary: View {
    let snapshot: MonitorSnapshot
    let colors: WidgetColors

    var body: some View {
        VStack(spacing: 6) {
            WidgetProcessorCard(snapshot: snapshot, colors: colors, compact: true)
            // 배터리 잔량은 메뉴 막대에서도 보여서 빼고, 순전력과 네트워크 ↓·↑를 보여줘요. (2026-10-30 사용자 요청)
            HStack(spacing: 6) {
                chip("메모리", snapshot.memory.usagePercent, ValueFormat.percent)
                chip("순전력", snapshot.battery.netPower, ValueFormat.signedWatts)
                chip("↓", snapshot.network.download, ValueFormat.rate, labelColor: colors(.network).color)
                chip("↑", snapshot.network.upload, ValueFormat.rate, labelColor: colors(.network).secondaryColor)
            }
            .frame(height: 20)
        }
    }

    private func chip(_ label: String, _ reading: Reading<Double>, _ format: @escaping (Double) -> String,
                      labelColor: Color? = nil) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: labelColor == nil ? 10 : 11, weight: labelColor == nil ? .regular : .semibold))
                .foregroundStyle(labelColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(HierarchicalShapeStyle.secondary))
            WidgetValueText(reading: reading, format: format, font: .system(size: 11, weight: .semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.045), in: ContainerRelativeShape())
    }
}

/// 큰 크기 요약: 3열 카드 · 메모리 · 온도·팬|배터리 · 네트워크
struct LargeSummary: View {
    let snapshot: MonitorSnapshot
    let colors: WidgetColors

    var body: some View {
        VStack(spacing: 6) {
            WidgetProcessorCard(snapshot: snapshot, colors: colors)
            memoryCard
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                thermalCard
                networkCard
            }
            .fixedSize(horizontal: false, vertical: true)
            batteryCard
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var memoryCard: some View {
        let memory = snapshot.memory
        return WidgetCard {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    WidgetCardTitle(title: "메모리")
                    Spacer(minLength: 4)
                    // 지금 쓰는 메모리 대역폭 (패널의 'DRAM 트래픽'과 같은 값)
                    Text("TRAFFIC")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    WidgetValueText(reading: memory.trafficTotal, format: ValueFormat.gigabytesPerSecond,
                                    font: .system(size: 11, weight: .semibold))
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    WidgetPressureLabel(reading: memory.pressure)
                }
                .lineLimit(1)
                HStack(spacing: 6) {
                    if let used = memory.used.okValue, let total = memory.total.okValue {
                        Text("\(ValueFormat.memoryNumber(used)) / \(ValueFormat.memoryNumber(total)) GB")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .fixedSize()
                    } else {
                        WidgetValueText(reading: memory.used, format: ValueFormat.memory)
                    }
                    WidgetUsageBar(fraction: memory.usagePercent.okValue.map { $0 / 100 },
                                   color: colors(.memory).color)
                    WidgetValueText(reading: memory.usagePercent, format: ValueFormat.percent)
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }
        }
    }

    private var thermalCard: some View {
        let thermal = snapshot.thermal
        return WidgetCard {
            VStack(alignment: .leading, spacing: 4) {
                WidgetCardTitle(title: "온도·팬")
                // 이름과 값을 붙여 두고 사이만 늘려요. (반 폭 카드에서 'GPU 71…'처럼 잘리던 문제)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    temperature("CPU", thermal.cpuMax)
                    Spacer(minLength: 4)
                    temperature("GPU", thermal.gpuMax)
                }
                .minimumScaleFactor(0.85)
                if let fans = thermal.fans.okValue {
                    ForEach(fans) { fan in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(FanName.long(id: fan.id, count: fans.count))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            if let rpm = fan.rpm.okValue, rpm < 1 {
                                Text("정지")
                                    .font(.system(size: 12, weight: .semibold))
                            } else {
                                WidgetValueText(reading: fan.rpm, format: ValueFormat.rpm,
                                                font: .system(size: 12, weight: .semibold))
                            }
                        }
                        .lineLimit(1)
                    }
                } else {
                    HStack {
                        Text("팬")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        WidgetStateText(state: thermal.fans.state)
                    }
                }
            }
        }
    }

    private func temperature(_ label: String, _ reading: Reading<Double>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            WidgetValueText(reading: reading, format: ValueFormat.celsius, font: .system(size: 12, weight: .semibold))
        }
        .fixedSize()
    }

    /// 긴 배터리 카드: 잔량 막대, 충전·방전과 남은 시간, 순전력
    private var batteryCard: some View {
        let battery = snapshot.battery
        return WidgetCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    WidgetCardTitle(title: "배터리")
                    WidgetUsageBar(fraction: battery.level.okValue.map { $0 / 100 }, color: colors(.battery).color)
                    WidgetValueText(reading: battery.level, format: ValueFormat.percent)
                        .frame(minWidth: 32, alignment: .trailing)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(chargeText(battery))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Text("순전력")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    WidgetValueText(reading: battery.netPower, format: ValueFormat.signedWatts,
                                    font: .system(size: 12, weight: .semibold))
                }
            }
        }
    }

    /// 반 폭 네트워크 카드: 줄마다 지금 속도와 오늘 누적 (좌·우 팬처럼 ↓·↑ 짝)
    private var networkCard: some View {
        let network = snapshot.network
        let color = colors(.network)
        return WidgetCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    WidgetCardTitle(title: "네트워크")
                    Spacer(minLength: 4)
                    Text(todayLabel(network.todayDate))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                rateRow("↓", network.download, network.todayDownloaded, color.color)
                rateRow("↑", network.upload, network.todayUploaded, color.secondaryColor)
            }
        }
    }

    /// '↓ 168 KB/s ⋯ 17 GB'
    private func rateRow(_ arrow: String, _ rate: Reading<Double>, _ total: Reading<Double>,
                         _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(arrow)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            WidgetValueText(reading: rate, format: ValueFormat.rate, font: .system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            WidgetValueText(reading: total, format: ValueFormat.byteCount, font: .system(size: 10))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    /// 기준 날짜가 오늘이 아니면 '오늘' 대신 날짜 (docs/WIDGET_V2.md 3장)
    private func todayLabel(_ date: Date?) -> String {
        guard let date else { return "오늘" }
        return Calendar.current.isDateInToday(date) ? "오늘" : ValueFormat.monthDay(date)
    }

    /// '방전 중 · 3시간 10분 남음' (패널 배터리 카드와 같은 문구)
    private func chargeText(_ battery: BatterySnapshot) -> String {
        guard let state = battery.chargeState.okValue else {
            switch battery.chargeState.state {
            case .unsupported: return "배터리 없음"
            case .preparing: return "준비 중"
            default: return ""
            }
        }
        let time = battery.timeRemaining.okValue
        switch state {
        case .charging:
            if let time { return "충전 중 · 완충까지 \(ValueFormat.duration(time))" }
            if battery.timeRemaining.state == .preparing { return "충전 중 · 완충 시간 계산 중" }
            return "충전 중"
        case .discharging:
            if let time { return "방전 중 · \(ValueFormat.duration(time)) 남음" }
            if battery.timeRemaining.state == .preparing { return "방전 중 · 남은 시간 계산 중" }
            return "방전 중"
        case .charged:
            return "완충"
        case .onHold:
            return "충전 보류"
        }
    }
}

// MARK: - 그래프 카드 (그래프 위젯 GraphWidgets.swift가 써요)

/// 그래프 카드 하나: 제목 · 범례(지금 값) · 꺾은선
struct WidgetGraphCard: View {
    struct Legend: Identifiable {
        let label: String
        let color: Color
        var dashed = false
        let value: String
        var id: String { label }
    }

    let title: String
    let legends: [Legend]
    let lines: [WidgetLine]
    var fixedMaximum: Double?
    var minimumMaximum: Double = 1
    /// 0을 가운데 둘지 (배터리 순전력)
    var symmetric = false
    /// 왼쪽 눈금 글자
    var axisFormat: ((Double) -> String)?

    var body: some View {
        WidgetCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    WidgetCardTitle(title: title)
                    Spacer(minLength: 4)
                    Text("10분")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(legends) { legend in
                        WidgetLegendItem(color: legend.color, dashed: legend.dashed,
                                         label: legend.label, value: legend.value)
                    }
                    Spacer(minLength: 0)
                }
                .minimumScaleFactor(0.8)
                WidgetSparkline(lines: lines, fixedMaximum: fixedMaximum, minimumMaximum: minimumMaximum,
                                symmetric: symmetric, axisFormat: axisFormat)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// 범례에 쓸 지금 값. 정상이 아니면 짧은 상태 글자예요. (0으로 보여주지 않아요)
func widgetLegendValue(_ reading: Reading<Double>, _ format: (Double) -> String) -> String {
    if let value = reading.okValue {
        return format(value)
    }
    switch reading.state {
    case .ok: return ValueFormat.unavailable
    case .stale: return reading.value.map(format) ?? ValueFormat.unavailable
    case .preparing: return "준비 중"
    case .unsupported: return "지원 안 함"
    case .permissionNeeded: return "권한 필요"
    case .notMeasurable: return "측정 불가"
    case .off: return "꺼짐"
    case .failed: return "읽지 못함"
    }
}

/// 그래프 카드를 만드는 곳이에요. 중간·큰 크기가 함께 써요.
enum WidgetGraphs {
    static func usage(_ payload: WidgetPayload, _ colors: WidgetColors) -> WidgetGraphCard {
        let s = payload.snapshot
        let cpu = colors(.cpu)
        let gpu = colors(.gpu).color
        return WidgetGraphCard(
            title: "CPU·GPU 사용률",
            legends: [.init(label: "P", color: cpu.color, value: widgetLegendValue(s.cpu.performanceUsage, ValueFormat.percent)),
                      .init(label: "E", color: cpu.secondaryColor, dashed: true,
                            value: widgetLegendValue(s.cpu.efficiencyUsage, ValueFormat.percent)),
                      .init(label: "GPU", color: gpu, value: widgetLegendValue(s.gpu.usage, ValueFormat.percent))],
            lines: [WidgetLine(label: "E", values: payload.values(.cpuEfficiency), color: cpu.secondaryColor, dashed: true),
                    WidgetLine(label: "P", values: payload.values(.cpuPerformance), color: cpu.color),
                    WidgetLine(label: "GPU", values: payload.values(.gpuUsage), color: gpu)],
            fixedMaximum: 100,
            axisFormat: { "\(ValueFormat.compact($0))%" })
    }

    static func power(_ payload: WidgetPayload, _ colors: WidgetColors) -> WidgetGraphCard {
        let s = payload.snapshot
        let cpu = colors(.cpu).color, gpu = colors(.gpu).color, ane = colors(.ane).color
        return WidgetGraphCard(
            title: "전력",
            legends: [.init(label: "CPU", color: cpu, value: widgetLegendValue(s.cpu.power, ValueFormat.watts)),
                      .init(label: "GPU", color: gpu, value: widgetLegendValue(s.gpu.power, ValueFormat.watts)),
                      .init(label: "ANE", color: ane, value: widgetLegendValue(s.ane.power, ValueFormat.watts))],
            lines: [WidgetLine(label: "CPU", values: payload.values(.cpuPower), color: cpu),
                    WidgetLine(label: "GPU", values: payload.values(.gpuPower), color: gpu),
                    WidgetLine(label: "ANE", values: payload.values(.anePower), color: ane)],
            minimumMaximum: 1,
            axisFormat: ValueFormat.wattsScale)
    }

    static func temperature(_ payload: WidgetPayload, _ colors: WidgetColors) -> WidgetGraphCard {
        let s = payload.snapshot
        let thermal = colors(.thermal)
        return WidgetGraphCard(
            title: "온도",
            legends: [.init(label: "CPU", color: thermal.color, value: widgetLegendValue(s.thermal.cpuMax, ValueFormat.celsius)),
                      .init(label: "GPU", color: thermal.secondaryColor, dashed: true,
                            value: widgetLegendValue(s.thermal.gpuMax, ValueFormat.celsius))],
            lines: [WidgetLine(label: "GPU", values: payload.values(.gpuTemperature), color: thermal.secondaryColor, dashed: true),
                    WidgetLine(label: "CPU", values: payload.values(.cpuTemperature), color: thermal.color)],
            fixedMaximum: 100,
            axisFormat: { "\(ValueFormat.compact($0))°" })
    }

    static func network(_ payload: WidgetPayload, _ colors: WidgetColors) -> WidgetGraphCard {
        let s = payload.snapshot
        let network = colors(.network)
        return WidgetGraphCard(
            title: "네트워크",
            legends: [.init(label: "↓", color: network.color, value: widgetLegendValue(s.network.download, ValueFormat.rate)),
                      .init(label: "↑", color: network.secondaryColor, dashed: true,
                            value: widgetLegendValue(s.network.upload, ValueFormat.rate))],
            lines: [WidgetLine(label: "↑", values: payload.values(.networkUpload), color: network.secondaryColor, dashed: true),
                    WidgetLine(label: "↓", values: payload.values(.networkDownload), color: network.color)],
            minimumMaximum: 10_000,
            axisFormat: shortRate)
    }

    /// 팬 회전수: 오른쪽 진한 실선, 왼쪽 연한 점선 (docs/FAN_CONTROL.md '팬 이름')
    static func fan(_ payload: WidgetPayload, _ colors: WidgetColors) -> WidgetGraphCard {
        let thermal = colors(.thermal)
        let fansReading = payload.snapshot.thermal.fans
        let fans = fansReading.okValue ?? []
        let count = fans.isEmpty ? 2 : fans.count
        let keys: [WidgetSeriesKey] = [.fan0, .fan1]
        var lines: [WidgetLine] = []
        var legends: [WidgetGraphCard.Legend] = []
        for (id, key) in keys.enumerated() where id < count {
            let light = FanName.isLight(id: id, count: count)
            let color = light ? thermal.secondaryColor : thermal.color
            let name = FanName.short(id: id, count: count)
            lines.append(WidgetLine(label: name, values: payload.values(key), color: color, dashed: light))
            let value: String
            if let rpm = fans.first(where: { $0.id == id })?.rpm {
                value = rpm.okValue.map { $0 < 1 ? "정지" : ValueFormat.rpm($0) } ?? widgetLegendValue(rpm, ValueFormat.rpm)
            } else {
                value = widgetLegendValue(Reading<Double>(value: nil, state: fansReading.state, measuredAt: nil),
                                          ValueFormat.rpm)
            }
            legends.append(.init(label: name, color: color, dashed: light, value: value))
        }
        // 진한 선이 위에 오게 연한 선을 먼저 그려요.
        lines.sort { $0.dashed && !$1.dashed }
        return WidgetGraphCard(title: "팬", legends: legends, lines: lines,
                               minimumMaximum: 2_000,
                               axisFormat: { ValueFormat.compact($0) })
    }

    /// 배터리 순전력: 0을 가운데 두고 + 충전 · − 방전
    static func battery(_ payload: WidgetPayload, _ colors: WidgetColors) -> WidgetGraphCard {
        let battery = colors(.battery).color
        let netPower = payload.snapshot.battery.netPower
        return WidgetGraphCard(
            title: "배터리 순전력",
            legends: [.init(label: "순전력", color: battery, value: widgetLegendValue(netPower, ValueFormat.signedWatts))],
            lines: [WidgetLine(label: "순전력", values: payload.values(.batteryNetPower), color: battery)],
            minimumMaximum: 5,
            symmetric: true,
            axisFormat: { value in
                if abs(value) < 0.001 { return "0" }
                return "\(value > 0 ? "+" : "−")\(ValueFormat.compact(abs(value))) W"
            })
    }

    /// 눈금용 짧은 속도: 500 KB, 4 MB ('/s'는 범례에 있어서 빼요)
    static func shortRate(_ bytesPerSecond: Double) -> String {
        let text = ValueFormat.rateScale(bytesPerSecond)
        return text.hasSuffix("/s") ? String(text.dropLast(2)) : text
    }
}
