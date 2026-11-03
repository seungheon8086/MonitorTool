import Charts
import SwiftUI

/// 그래프에 그릴 계열 하나예요.
struct ChartLine: Identifiable {
    let metric: Metric
    /// 이름 (범례·구분용, 그래프 안에서 겹치지 않게)
    let label: String
    let color: Color
    /// 점선으로 그릴지 (같은 항목의 두 번째 계열, 예: 왼쪽 팬)
    var dashed: Bool = false

    var id: String { label }
}

/// 그래프 모양이에요.
enum ChartStyle {
    /// 선만 그려요.
    case lines
    /// 선 아래를 연하게 채워요. (메모리 사용량)
    case filled
    /// 아래에서부터 면을 쌓아요. (기기별 메모리 트래픽)
    case stacked
}

/// 상세 카드 안의 그래프 한 개예요. (화면 시안 '패널 펼침')
/// 제목 줄 → 왼쪽 눈금(위·가운데·아래) + 그래프 → '1분 전 · 지금' 줄로 이뤄져요.
/// 눈금은 그래프 왼쪽의 고정 폭 칸에 두고, 단위는 맨 위 눈금에만 붙여요. (2026-11-03 사용자 결정 A안)
/// 재지 못한 구간은 선을 끊고 비워 둬요. 0으로 이어 그리지 않아요. (설계 문서 4장)
struct HistoryChart<Trailing: View>: View {
    @Environment(MonitorStore.self) private var store

    let title: String
    let lines: [ChartLine]
    let period: ChartPeriod
    let scale: ChartScale
    var style: ChartStyle = .lines
    var height: CGFloat = 56
    /// 기록이 없을 때 이유를 알려 줄 상태 (예: 권한 필요)
    var emptyState: ValueState? = nil
    /// 눈금 값을 글로 바꿔요. (예: 8 → '8 W')
    let scaleText: (Double) -> String

    /// 눈금 칸의 폭. 한 상세 카드 안의 그래프들이 세로로 줄이 맞도록 모두 같아요.
    static var axisWidth: CGFloat { 44 }
    /// 눈금 칸과 그래프 사이
    static var axisSpacing: CGFloat { 4 }
    /// 제목 오른쪽 (지금 값이나 범례)
    @ViewBuilder let trailing: Trailing

    var body: some View {
        let window = ChartWindow(period: period, end: store.snapshot.takenAt ?? .now)
        let plot = ChartPlot.make(lines: lines, style: style, scale: scale, history: store.history, window: window)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            HStack(alignment: .top, spacing: Self.axisSpacing) {
                ChartAxisLabels(labels: ChartAxisText.labels(for: plot.range, format: scaleText),
                                height: height)
                    .frame(width: Self.axisWidth)
                    .accessibilityHidden(true)
                HistoryChartCanvas(plot: plot, window: window)
                    .frame(height: height)
                    .overlay {
                        if plot.isEmpty {
                            Text(emptyMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("최근 \(period.title) \(title) 그래프, 위쪽 선 \(scaleText(plot.range.upper))"))
            }
            // 맨 위 눈금 글이 위쪽 선보다 반 줄 올라가서 제목 줄과 붙지 않게 띄워요.
            .padding(.top, 4)
            HStack {
                Text(period.startLabel)
                Spacer(minLength: 8)
                Text("지금")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.leading, Self.axisWidth + Self.axisSpacing)
        }
    }

    /// 기록이 없을 때 그래프 가운데에 보여줄 글
    private var emptyMessage: String {
        switch emptyState {
        case .permissionNeeded: ""
        case .unsupported: "이 Mac은 해당 기능을 지원하지 않음"
        case .notMeasurable: "측정 불가"
        default: ""
        }
    }
}

/// 그래프 왼쪽 눈금 세 개 (위쪽 선·가운데 선·바닥 선 높이에 맞춰요)
private struct ChartAxisLabels: View {
    let labels: ChartAxisText.Labels
    let height: CGFloat

    /// 눈금 글 한 줄의 높이. 글 가운데가 선 높이에 오도록 위아래로 이 절반만큼 내밀어요.
    private static let lineHeight: CGFloat = 12

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            label(labels.top)
            Spacer(minLength: 0)
            label(labels.middle)
            Spacer(minLength: 0)
            label(labels.bottom)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: height + Self.lineHeight)
        .padding(.vertical, -Self.lineHeight / 2)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(height: Self.lineHeight)
    }
}

/// 눈금 글을 만들어요. 단위는 맨 위 눈금에만 붙이고, 가운데 눈금의 단위가 위와 다를 때만
/// (예: 위 '1.5 MB/s', 가운데 '750 KB/s') 가운데에도 붙여요.
enum ChartAxisText {
    struct Labels: Equatable {
        var top: String
        var middle: String
        var bottom: String
    }

    static func labels(for range: ChartRange, format: (Double) -> String) -> Labels {
        let top = split(format(range.upper))
        if range.isSymmetric {
            // 배터리 순전력: 위 '10 W', 가운데 '0', 아래 '−10'
            return Labels(top: format(range.upper), middle: "0", bottom: "−\(top.number)")
        }
        let middleValue = (range.upper + range.lower) / 2
        let middle = split(format(middleValue))
        let middleText = middle.unit == top.unit || middle.unit.isEmpty ? middle.number : format(middleValue)
        return Labels(top: format(range.upper), middle: middleText, bottom: "0")
    }

    /// '8 W' → ('8', 'W'), '100%' → ('100', '%'), '4' → ('4', '')
    static func split(_ text: String) -> (number: String, unit: String) {
        if let space = text.firstIndex(of: " ") {
            return (String(text[..<space]), String(text[text.index(after: space)...]))
        }
        if text.hasSuffix("%") {
            return (String(text.dropLast()), "%")
        }
        return (text, "")
    }
}

/// 그릴 준비를 마친 그래프 데이터예요.
struct ChartPlot {
    /// 선 한 토막
    struct Segment: Identifiable {
        let id: String
        let color: Color
        let dashed: Bool
        let points: [ChartPoint]
    }

    /// 면 한 토막 (아래·위 경계)
    struct Band: Identifiable {
        let id: String
        let color: Color
        let points: [BandPoint]
    }

    struct BandPoint {
        let date: Date
        let lower: Double
        let upper: Double
    }

    var segments: [Segment] = []
    var bands: [Band] = []
    var range: ChartRange

    var isEmpty: Bool {
        segments.isEmpty && bands.isEmpty
    }
}

extension ChartPlot {
    static func make(lines: [ChartLine], style: ChartStyle, scale: ChartScale,
                     history: MetricHistory, window: ChartWindow) -> ChartPlot {
        switch style {
        case .lines:
            return makeLines(lines, filled: false, scale: scale, history: history, window: window)
        case .filled:
            return makeLines(lines, filled: true, scale: scale, history: history, window: window)
        case .stacked:
            return makeStacked(lines, scale: scale, history: history, window: window)
        }
    }

    private static func makeLines(_ lines: [ChartLine], filled: Bool, scale: ChartScale,
                                  history: MetricHistory, window: ChartWindow) -> ChartPlot {
        let runsByLine: [[ChartRun]] = lines.map { line in
            ChartData.lineRuns(history.samples(for: line.metric), in: window,
                               maxGap: window.maxGap(for: line.metric))
        }
        let values: [Double] = runsByLine.flatMap { runs in
            runs.flatMap { run in run.points.map(\.value) }
        }
        let range = scale.range(for: values)

        var plot = ChartPlot(range: range)
        for (line, runs) in zip(lines, runsByLine) {
            for (number, run) in runs.enumerated() {
                let id = "\(line.label)-\(number)"
                let points = run.points.map { ChartPoint(date: $0.date, value: range.clamped($0.value)) }
                plot.segments.append(Segment(id: id, color: line.color, dashed: line.dashed, points: points))
                if filled {
                    let bandPoints = points.map { BandPoint(date: $0.date, lower: range.lower, upper: $0.value) }
                    plot.bands.append(Band(id: id, color: line.color.opacity(0.14), points: bandPoints))
                }
            }
        }
        return plot
    }

    private static func makeStacked(_ lines: [ChartLine], scale: ChartScale,
                                    history: MetricHistory, window: ChartWindow) -> ChartPlot {
        let maxGap = lines.map { window.maxGap(for: $0.metric) }.max() ?? 25
        let runs = ChartData.stackedRuns(lines.map { history.samples(for: $0.metric) }, in: window, maxGap: maxGap)
        let totals: [Double] = runs.flatMap { run in run.points.compactMap(\.tops.last) }
        let range = scale.range(for: totals)

        var plot = ChartPlot(range: range)
        for (number, run) in runs.enumerated() {
            for (layer, line) in lines.enumerated() {
                let bandPoints = run.points.map { point in
                    BandPoint(date: point.date,
                              lower: layer == 0 ? range.lower : range.clamped(point.tops[layer - 1]),
                              upper: range.clamped(point.tops[layer]))
                }
                plot.bands.append(Band(id: "\(line.label)-\(number)", color: line.color, points: bandPoints))
            }
        }
        return plot
    }
}

/// Swift Charts로 그리는 부분이에요. 축은 숨기고 위쪽·가운데·바닥 선만 그려요. (화면 시안과 같게)
private struct HistoryChartCanvas: View {
    let plot: ChartPlot
    let window: ChartWindow

    var body: some View {
        Chart {
            guideMarks
            bandMarks
            lineMarks
        }
        .chartXScale(domain: window.start ... window.end)
        .chartYScale(domain: plot.range.lower ... plot.range.upper)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }

    /// 위쪽 선, 가운데 선(점선, 대칭 그래프에서는 0 선), 바닥 선. 가운데 선은 모든 그래프에 그려요. (왼쪽 가운데 눈금과 짝)
    @ChartContentBuilder
    private var guideMarks: some ChartContent {
        RuleMark(y: .value("위쪽 선", plot.range.upper))
            .foregroundStyle(Color.primary.opacity(0.08))
            .lineStyle(StrokeStyle(lineWidth: 1))
        RuleMark(y: .value("가운데 선", (plot.range.upper + plot.range.lower) / 2))
            .foregroundStyle(Color.primary.opacity(plot.range.isSymmetric ? 0.22 : 0.10))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: plot.range.isSymmetric ? [] : [2, 3]))
        RuleMark(y: .value("바닥 선", plot.range.lower))
            .foregroundStyle(Color.primary.opacity(plot.range.isSymmetric ? 0.08 : 0.14))
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    /// 채운 면 (메모리 사용량, 누적 트래픽)
    @ChartContentBuilder
    private var bandMarks: some ChartContent {
        ForEach(plot.bands) { band in
            ForEach(band.points, id: \.date) { point in
                AreaMark(x: .value("시각", point.date),
                         yStart: .value("아래", point.lower),
                         yEnd: .value("위", point.upper),
                         series: .value("면", band.id))
                    .foregroundStyle(band.color)
            }
        }
    }

    /// 선. 토막마다 series를 따로 줘서 끊긴 곳을 잇지 않아요.
    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        ForEach(plot.segments) { segment in
            ForEach(segment.points, id: \.date) { point in
                LineMark(x: .value("시각", point.date),
                         y: .value("값", point.value),
                         series: .value("선", segment.id))
                    .foregroundStyle(segment.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round,
                                           dash: segment.dashed ? [4, 3] : []))
            }
            // 점이 하나뿐인 토막은 선이 그려지지 않아서 작은 점으로 보여줘요.
            if segment.points.count == 1, let point = segment.points.first {
                PointMark(x: .value("시각", point.date), y: .value("값", point.value))
                    .foregroundStyle(segment.color)
                    .symbolSize(12)
            }
        }
    }
}
