import Foundation
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
    /// 제목 아래 작은 세부 줄 (예: 디스크 활성 시간의 '추정'). 없으면 줄을 두지 않아요.
    var note: String? = nil
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
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

/// 그래프 왼쪽 눈금 세 개 (위쪽 선·가운데 선(또는 0 선)·바닥 선 높이에 맞춰요)
private struct ChartAxisLabels: View {
    let labels: ChartAxisText.Labels
    let height: CGFloat

    /// 눈금 글 한 줄의 높이. 글 가운데가 선 높이에 오도록 이 절반만큼 올려요.
    private static let lineHeight: CGFloat = 12

    var body: some View {
        ZStack(alignment: .topTrailing) {
            label(labels.top, at: 0)
            // 가운데 눈금이 위·아래 눈금과 겹칠 만큼 가까우면 (0 선이 끝에 붙은 경우) 빼요.
            if labels.middleFraction * height >= Self.lineHeight,
               (1 - labels.middleFraction) * height >= Self.lineHeight {
                label(labels.middle, at: labels.middleFraction * height)
            }
            label(labels.bottom, at: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .frame(height: height)
    }

    private func label(_ text: String, at y: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(height: Self.lineHeight)
            .offset(y: y - Self.lineHeight / 2)
    }
}

/// 눈금 글을 만들어요. 단위는 맨 위 눈금에만 붙이고, 가운데 눈금의 단위가 위와 다를 때만
/// (예: 위 '1.5 MB/s', 가운데 '750 KB/s') 가운데에도 붙여요.
enum ChartAxisText {
    struct Labels: Equatable {
        var top: String
        var middle: String
        var bottom: String
        /// 가운데 눈금 높이 (0 = 위쪽 선, 1 = 바닥 선)
        var middleFraction: CGFloat
    }

    static func labels(for range: ChartRange, format: (Double) -> String) -> Labels {
        let top = split(format(range.upper))
        let middleText: String
        if range.crossesZero {
            // 배터리 순전력: 0 선 높이에 '0'
            middleText = "0"
        } else {
            let middle = split(format(range.middleValue))
            let text = middle.unit == top.unit || middle.unit.isEmpty ? middle.number : format(range.middleValue)
            // 방전만 하는 구간(−15 ~ 0 W)의 가운데 '−7.5'도 빼기 기호로 맞춰요.
            middleText = text.replacingOccurrences(of: "-", with: "−")
        }
        // 바닥이 0이 아닌 그래프(온도, 방전)는 바닥 값을 그대로 적어요. 음수는 '−15'처럼 써요.
        let bottomText: String
        if range.lower == 0 {
            bottomText = "0"
        } else if range.lower < 0 {
            bottomText = "−" + split(format(-range.lower)).number
        } else {
            bottomText = split(format(range.lower)).number
        }
        return Labels(top: format(range.upper), middle: middleText, bottom: bottomText,
                      middleFraction: CGFloat(range.middleFraction))
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

    /// 위쪽 선, 가운데 선(점선. 0이 범위 안이면 그 높이의 진한 0 선), 바닥 선. 가운데 선은 모든 그래프에 그려요. (왼쪽 가운데 눈금과 짝)
    @ChartContentBuilder
    private var guideMarks: some ChartContent {
        let range = plot.range
        RuleMark(y: .value("위쪽 선", range.upper))
            .foregroundStyle(Color.primary.opacity(0.08))
            .lineStyle(StrokeStyle(lineWidth: 1))
        RuleMark(y: .value("가운데 선", range.middleValue))
            .foregroundStyle(Color.primary.opacity(range.crossesZero ? 0.22 : 0.10))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: range.crossesZero ? [] : [2, 3]))
        RuleMark(y: .value("바닥 선", range.lower))
            .foregroundStyle(Color.primary.opacity(range.lower < 0 ? 0.08 : 0.14))
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
