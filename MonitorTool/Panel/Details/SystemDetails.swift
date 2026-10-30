import Foundation
import SwiftUI

// 메모리·온도·팬·배터리·네트워크 카드를 눌렀을 때 아래로 펼쳐지는 상세예요.
// 그래프 기간(1분·5분·30분)은 카드마다 따로 고르고, 고른 기간은 앱을 다시 켜도 남아요.

// MARK: - 메모리

struct MemoryDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("chartPeriod.memory") private var period: ChartPeriod = .oneMinute

    private var memory: MemorySnapshot { store.snapshot.memory }

    var body: some View {
        DetailCard(title: "메모리 자세히") {
            PeriodPicker(period: $period)
        } content: {
            usageChart
            summaryRow
            Divider()
            trafficChart
            DeviceTrafficGrid(memory: memory)
        }
    }

    /// 사용량 그래프. 위쪽 선은 전체 메모리예요.
    private var usageChart: some View {
        HistoryChart(title: "사용량",
                     lines: [ChartLine(metric: .memoryUsed, label: "사용량",
                                       color: appearance.color(for: .memory).color)],
                     period: period,
                     scale: usageScale,
                     style: .filled,
                     height: 64,
                     emptyState: memory.used.state,
                     scaleText: ValueFormat.memory) {
            MemoryAmountText(used: memory.used, total: memory.total, font: .system(size: 12))
        }
    }

    private var usageScale: ChartScale {
        if let total = memory.total.okValue {
            return .fixed(total, midline: false)
        }
        return .automatic(minimum: 1_073_741_824)
    }

    /// 메모리 압력 · 압축 · 스왑
    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("메모리 압력")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                PressureValue(reading: memory.pressure)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LabeledValue(label: "압축", reading: memory.compressed, format: ValueFormat.memory,
                         font: .system(size: 14, weight: .semibold))
            LabeledValue(label: "스왑", reading: memory.swapUsed, format: ValueFormat.memory,
                         font: .system(size: 14, weight: .semibold))
        }
    }

    /// 기기별 DRAM 트래픽을 아래에서부터 쌓은 그래프 (CPU → GPU → ANE → 그 밖)
    private var trafficChart: some View {
        HistoryChart(title: "DRAM 트래픽",
                     lines: trafficLines,
                     period: period,
                     scale: .automatic(minimum: 1_000_000_000),
                     style: .stacked,
                     height: 90,
                     emptyState: memory.trafficTotal.state,
                     scaleText: ValueFormat.gigabytesPerSecondScale) {
            ReadWriteText(read: memory.trafficRead, write: memory.trafficWrite)
        }
    }

    private var trafficLines: [ChartLine] {
        [ChartLine(metric: .traffic(.cpu), label: "CPU", color: appearance.color(for: .cpu).color.opacity(0.75)),
         ChartLine(metric: .traffic(.gpu), label: "GPU", color: appearance.color(for: .gpu).color.opacity(0.75)),
         ChartLine(metric: .traffic(.ane), label: "ANE", color: appearance.color(for: .ane).color.opacity(0.75)),
         ChartLine(metric: .traffic(.other), label: "그 밖", color: StatusColor.otherTraffic)]
    }
}

/// 상세 화면의 메모리 압력 ('● 정상')
struct PressureValue: View {
    let reading: Reading<MemoryPressure>

    var body: some View {
        if let pressure = reading.okValue {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: pressure))
                    .frame(width: 7, height: 7)
                Text(title(for: pressure))
                    .font(.system(size: 14, weight: .semibold))
            }
        } else {
            StateText(state: reading.state)
        }
    }

    private func title(for pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "정상"
        case .warning: "주의"
        case .critical: "높음"
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

/// '읽기 6.1 · 쓰기 3.7 GB/s'
struct ReadWriteText: View {
    let read: Reading<Double>
    let write: Reading<Double>

    var body: some View {
        if let readBytes = read.okValue, let writeBytes = write.okValue {
            Text("읽기 \(ValueFormat.gigabytesPerSecondNumber(readBytes)) · 쓰기 \(ValueFormat.gigabytesPerSecondNumber(writeBytes)) GB/s")
                .font(.system(size: 12))
                .monospacedDigit()
        } else {
            StateText(state: read.state == .ok ? write.state : read.state)
        }
    }
}

/// 기기별 DRAM 트래픽 (누적 그래프의 범례 역할도 해요). CPU·GPU·ANE는 항목 색, 나머지는 회색이에요.
struct DeviceTrafficGrid: View {
    let memory: MemorySnapshot
    @Environment(AppearanceSettings.self) private var appearance

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)
    }

    var body: some View {
        if memory.trafficByDevice.isEmpty {
            StateText(state: memory.trafficTotal.state)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(memory.trafficByDevice) { traffic in
                    ColorChip(color: color(for: traffic.device),
                              text: "\(name(for: traffic.device)) \(ValueFormat.gigabytesPerSecondNumber(traffic.bytesPerSecond))")
                }
            }
        }
    }

    private func name(for device: TrafficDevice) -> String {
        switch device {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ane: "ANE"
        case .display: "화면"
        case .storage: "저장장치"
        case .other: "그 밖"
        }
    }

    private func color(for device: TrafficDevice) -> Color {
        switch device {
        case .cpu: appearance.color(for: .cpu).color
        case .gpu: appearance.color(for: .gpu).color
        case .ane: appearance.color(for: .ane).color
        case .display, .storage, .other: StatusColor.otherTraffic
        }
    }
}

// MARK: - 온도·팬

struct ThermalDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("chartPeriod.thermal") private var period: ChartPeriod = .oneMinute

    private var thermal: ThermalSnapshot { store.snapshot.thermal }

    var body: some View {
        DetailCard(title: "온도·팬 자세히") {
            PeriodPicker(period: $period)
        } content: {
            temperatureChart
            sensorList
            if thermal.fans.state != .unsupported {
                Divider()
                fanChart
            }
            FanCards(fans: thermal.fans)
        }
    }

    /// CPU·GPU 최고 온도 그래프 (선 색은 CPU·GPU 항목 색)
    private var temperatureChart: some View {
        let cpuColor = appearance.color(for: .cpu).color
        let gpuColor = appearance.color(for: .gpu).color
        return HistoryChart(title: "온도",
                            lines: [ChartLine(metric: .cpuTemperature, label: "CPU 최고", color: cpuColor),
                                    ChartLine(metric: .gpuTemperature, label: "GPU 최고", color: gpuColor)],
                            period: period,
                            scale: .fixed(100, midline: true),
                            height: 80,
                            emptyState: thermal.cpuMax.state,
                            scaleText: ValueFormat.celsius) {
            HStack(spacing: 10) {
                LegendValue(color: cpuColor, label: "CPU 최고", reading: thermal.cpuMax, format: ValueFormat.celsius)
                LegendValue(color: gpuColor, label: "GPU 최고", reading: thermal.gpuMax, format: ValueFormat.celsius)
            }
        }
    }

    /// 센서별 온도 목록
    private var sensorList: some View {
        let ane = store.snapshot.ane
        return VStack(spacing: 0) {
            ListRow(title: "CPU 최고", note: "코어 센서 10개") {
                ValueText(reading: thermal.cpuMax, format: ValueFormat.celsius, font: Self.valueFont)
            }
            Divider()
            ListRow(title: "GPU 최고", note: "센서 2개") {
                ValueText(reading: thermal.gpuMax, format: ValueFormat.celsius, font: Self.valueFont)
            }
            Divider()
            ListRow(title: "ANE", note: "켜져 있을 때만") {
                ValueText(reading: ane.temperature, format: ValueFormat.celsius, font: Self.valueFont)
            }
            Divider()
            ListRow(title: "배터리") {
                ValueText(reading: thermal.battery, format: ValueFormat.celsius, font: Self.valueFont)
            }
            Divider()
            ListRow(title: "SSD") {
                ValueText(reading: thermal.ssd, format: ValueFormat.celsius, font: Self.valueFont)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 팬 회전수 그래프 (팬 1은 진하게, 팬 2는 연한 점선)
    private var fanChart: some View {
        HistoryChart(title: "팬 회전수",
                     lines: fanLines,
                     period: period,
                     scale: fanScale,
                     height: 56,
                     emptyState: thermal.fans.state,
                     scaleText: ValueFormat.rpm) {
            HStack(spacing: 10) {
                ForEach(fanLines) { line in
                    LegendLabel(color: line.color, dashed: line.dashed, label: line.label)
                }
            }
        }
    }

    private var fanLines: [ChartLine] {
        let color = appearance.color(for: .thermal)
        let fans = thermal.fans.okValue ?? []
        return fans.enumerated().map { index, fan in
            ChartLine(metric: .fan(fan.id), label: "팬 \(fan.id + 1)",
                      color: index == 0 ? color.color : color.secondaryColor,
                      dashed: index > 0)
        }
    }

    /// 위쪽 선: 팬 최대 회전수를 보기 좋게 올린 값 (예: 4,744 → 5,000 RPM)
    private var fanScale: ChartScale {
        let maximums = (thermal.fans.okValue ?? []).compactMap(\.maximumRPM)
        guard let largest = maximums.max() else {
            return .automatic(minimum: 1000)
        }
        return .fixed(ChartData.niceCeiling(largest), midline: false)
    }

    private static let valueFont = Font.system(size: 12, weight: .semibold)
}

/// 팬마다 회전수, 범위, 모드를 보여줘요.
struct FanCards: View {
    let fans: Reading<[FanReading]>

    private var columns: [GridItem] {
        [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    }

    var body: some View {
        if let list = fans.okValue {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(list) { fan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: fan))
                            .font(.system(size: 12, weight: .semibold))
                        Text(rangeText(for: fan))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("모드: \(modeText(for: fan.mode))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        } else {
            HStack {
                Text("팬")
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                StateText(state: fans.state)
            }
        }
    }

    /// '팬 1 · 정지', '팬 2 · 2,140 RPM'
    private func title(for fan: FanReading) -> String {
        let number = fan.id + 1
        guard let rpm = fan.rpm.okValue else { return "팬 \(number) · 읽지 못함" }
        return rpm < 1 ? "팬 \(number) · 정지" : "팬 \(number) · \(ValueFormat.rpm(rpm))"
    }

    /// '0 RPM · 범위 1,499–4,296'
    private func rangeText(for fan: FanReading) -> String {
        let current = fan.rpm.okValue.map(ValueFormat.rpm) ?? "—"
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM else { return current }
        return "\(current) · 범위 \(ValueFormat.compact(minimum.rounded()))–\(ValueFormat.compact(maximum.rounded()))"
    }

    private func modeText(for mode: FanMode) -> String {
        switch mode {
        case .automatic: "시스템 자동"
        case .manual: "수동"
        case .unknown: "알 수 없음"
        }
    }
}

// MARK: - 배터리

struct BatteryDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("chartPeriod.battery") private var period: ChartPeriod = .oneMinute

    private var battery: BatterySnapshot { store.snapshot.battery }

    var body: some View {
        DetailCard(title: "배터리 자세히") {
            PeriodPicker(period: $period)
        } content: {
            powerChart
            summaryRow
        }
    }

    /// 순전력 그래프. 0 선 위는 충전, 아래는 방전이에요.
    private var powerChart: some View {
        HistoryChart(title: "순전력 (위: 충전, 아래: 방전)",
                     lines: [ChartLine(metric: .batteryNetPower, label: "순전력",
                                       color: appearance.color(for: .battery).color)],
                     period: period,
                     scale: .symmetric(minimum: 10),
                     height: 64,
                     emptyState: battery.netPower.state,
                     scaleText: ValueFormat.wattsScale) {
            ValueText(reading: battery.netPower, format: ValueFormat.signedWatts, font: .system(size: 12))
        }
    }

    /// 성능 상태 · 최대 용량 · 사이클 수
    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 8) {
            LabeledValue(label: "성능 상태", reading: battery.condition, format: { $0 },
                         font: .system(size: 14, weight: .semibold))
            LabeledValue(label: "최대 용량", reading: battery.maximumCapacity, format: ValueFormat.percent,
                         font: .system(size: 14, weight: .semibold))
            LabeledValue(label: "사이클 수", reading: battery.cycleCount, format: { "\($0.formatted())회" },
                         font: .system(size: 14, weight: .semibold))
        }
    }
}

// MARK: - 네트워크

struct NetworkDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("chartPeriod.network") private var period: ChartPeriod = .oneMinute

    private var network: NetworkSnapshot { store.snapshot.network }

    var body: some View {
        DetailCard(title: "네트워크 자세히") {
            PeriodPicker(period: $period)
        } content: {
            speedChart
            totalsTable
            interfaceList
            if network.todayHasGap {
                SourceNote(text: "누적 일부 누락")
            }
        }
    }

    /// 받기·보내기 속도 그래프 (보내기는 연한 색)
    private var speedChart: some View {
        let color = appearance.color(for: .network)
        return HistoryChart(title: "속도",
                            lines: [ChartLine(metric: .networkDownload, label: "↓", color: color.color),
                                    ChartLine(metric: .networkUpload, label: "↑", color: color.secondaryColor)],
                            period: period,
                            scale: .automatic(minimum: 100_000),
                            height: 72,
                            emptyState: network.download.state,
                            scaleText: ValueFormat.rateScale) {
            HStack(spacing: 10) {
                LegendValue(color: color.color, label: "↓", reading: network.download, format: ValueFormat.rate)
                LegendValue(color: color.secondaryColor, label: "↑", reading: network.upload, format: ValueFormat.rate)
            }
        }
    }

    /// 오늘 · 이번 실행 누적
    private var totalsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            GridRow {
                Text("누적")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("↓ 받음")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text("↑ 보냄")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
            }
            Divider()
            GridRow {
                TotalTitle(title: "오늘", detail: network.todayDate.map(ValueFormat.monthDay))
                ValueText(reading: network.todayDownloaded, format: ValueFormat.byteCount, font: Self.valueFont)
                ValueText(reading: network.todayUploaded, format: ValueFormat.byteCount, font: Self.valueFont)
            }
            Divider()
            GridRow {
                TotalTitle(title: "이번 실행",
                           detail: network.sessionStartedAt.map { "\(ValueFormat.clockMinutes($0))부터" })
                ValueText(reading: network.sessionDownloaded, format: ValueFormat.byteCount, font: Self.valueFont)
                ValueText(reading: network.sessionUploaded, format: ValueFormat.byteCount, font: Self.valueFont)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 인터페이스별 속도
    private var interfaceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("인터페이스")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if network.interfaces.isEmpty {
                StateText(state: network.download.state)
            } else {
                ForEach(network.interfaces) { interface in
                    HStack(spacing: 4) {
                        Text(interface.displayName)
                        Text("(\(interface.id))")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("↓ \(ValueFormat.rate(interface.download)) · ↑ \(ValueFormat.rate(interface.upload))")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    private static let valueFont = Font.system(size: 12, weight: .semibold)
}

/// '오늘 · 10월 23일'
private struct TotalTitle: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12))
            if let detail {
                Text("· \(detail)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
