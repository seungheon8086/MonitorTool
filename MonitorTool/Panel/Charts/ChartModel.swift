import Foundation

// 최근 기록(MetricHistory)을 그래프용 점으로 바꾸는 계산이에요. 화면과 상관없는 계산만 모았어요.

/// 그래프 기간이에요. 상세 카드마다 따로 고르고, 고른 기간은 앱을 다시 켜도 남아요. (설계 문서 4장: 기본 1분)
nonisolated enum ChartPeriod: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case thirtyMinutes = 1800

    var id: Self { self }

    var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    var title: String {
        switch self {
        case .oneMinute: "1분"
        case .fiveMinutes: "5분"
        case .thirtyMinutes: "30분"
        }
    }

    /// 그래프 왼쪽 끝 글 (예: '1분 전')
    var startLabel: String {
        "\(title) 전"
    }

    /// 점 하나가 맡는 시간(초)이에요. 점이 180개를 넘지 않게 5분은 2초, 30분은 10초씩 묶어서 평균을 그려요.
    var bucketDuration: TimeInterval {
        switch self {
        case .oneMinute: 1
        case .fiveMinutes: 2
        case .thirtyMinutes: 10
        }
    }
}

/// 그래프에 보이는 시간 범위예요. 오른쪽 끝은 마지막으로 잰 시각이에요.
nonisolated struct ChartWindow: Hashable, Sendable {
    var start: Date
    var end: Date
    var bucketDuration: TimeInterval

    init(period: ChartPeriod, end: Date) {
        self.start = end.addingTimeInterval(-period.duration)
        self.end = end
        self.bucketDuration = period.bucketDuration
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }

    /// 두 점 사이가 이보다 길게 비면 선을 끊어요. (잠자기·수집 중단 구간)
    func maxGap(for metric: Metric) -> TimeInterval {
        max(metric.slowestInterval * 2.5, bucketDuration * 3)
    }
}

/// 그래프의 점 하나
nonisolated struct ChartPoint: Hashable, Sendable {
    var date: Date
    var value: Double
}

/// 끊기지 않고 이어지는 점들(선 한 토막)이에요.
nonisolated struct ChartRun: Hashable, Sendable {
    var points: [ChartPoint]
}

/// 누적 그래프의 점 하나예요. tops[i]는 0번부터 i번 층까지 더한 높이예요.
nonisolated struct StackedPoint: Hashable, Sendable {
    var date: Date
    var tops: [Double]
}

/// 끊기지 않고 이어지는 누적 점들이에요.
nonisolated struct StackedRun: Hashable, Sendable {
    var points: [StackedPoint]
}

/// 시간 칸 하나예요. 칸 안 기록의 평균이고, 칸 안 기록이 모두 빈칸이면 value가 nil이에요.
nonisolated struct ChartBucket: Hashable, Sendable {
    /// 그래프 왼쪽 끝부터 몇 번째 칸인지
    var index: Int
    /// 칸 안 기록 시각의 평균
    var date: Date
    var value: Double?
}

/// 그래프의 세로 범위를 정하는 방법이에요.
nonisolated enum ChartScale: Hashable, Sendable {
    /// 0–100 %, 가운데(50 %)에 점선
    case percent
    /// 고정된 위쪽 선 (예: 메모리 전체 용량, 온도 100 °C)
    case fixed(Double)
    /// 보이는 값에 맞춰 보기 좋은 위쪽 선을 고르되, 적어도 minimum은 둬요.
    case automatic(minimum: Double)
    /// 0을 가운데 두고 위아래로 같은 폭이에요. (배터리 순전력: 위는 충전, 아래는 방전)
    case symmetric(minimum: Double)
    /// 바이트 값을 GB(1024³) 단위로 보기 좋은 위쪽 선에 맞춰요. 적어도 minimum(바이트)은 둬요. (GPU 메모리)
    case automaticGigabytes(minimum: Double)
    /// 바닥도 0에 묶지 않고 보이는 값의 범위에 맞춰요. 위·아래 선은 step 단위로 끊고, 폭은 적어도 minimumSpan이에요.
    /// 바닥은 0 아래로 내려가지 않아요. (온도: 0–100 °C 고정이면 50 °C 안팎의 움직임이 납작하게 보여서)
    case floating(step: Double, minimumSpan: Double)
    /// 0 선은 늘 보이게 두고, 위·아래는 보이는 값까지만 step 단위로 넓혀요. 폭은 적어도 minimumSpan이에요.
    /// (배터리 순전력: 방전만 하면 0 ~ −15 W, 충전도 하면 −15 ~ +35 W처럼. 위아래를 같은 폭으로 두지 않아요)
    case zeroAnchored(step: Double, minimumSpan: Double)
}

/// 계산을 마친 세로 범위예요.
nonisolated struct ChartRange: Hashable, Sendable {
    var lower: Double
    var upper: Double

    /// 0이 위·아래 선 사이에 있는지 (배터리 순전력처럼 +·−가 함께 있는 그래프)
    var crossesZero: Bool {
        lower < 0 && upper > 0
    }

    /// 가운데 눈금·선의 값. 0이 범위 안에 있으면 0 선, 아니면 위아래 한가운데예요.
    var middleValue: Double {
        crossesZero ? 0 : (upper + lower) / 2
    }

    /// 가운데 선이 위쪽 선에서 얼마나 내려와 있는지 (0 = 위, 1 = 바닥)
    var middleFraction: Double {
        upper > lower ? (upper - middleValue) / (upper - lower) : 0.5
    }

    /// 범위 밖으로 나간 값은 경계에 맞춰요.
    func clamped(_ value: Double) -> Double {
        min(max(value, lower), upper)
    }
}

extension ChartScale {
    /// 보이는 값들로 세로 범위를 정해요.
    nonisolated func range(for values: [Double]) -> ChartRange {
        switch self {
        case .percent:
            return ChartRange(lower: 0, upper: 100)
        case let .fixed(upper):
            return ChartRange(lower: 0, upper: upper > 0 ? upper : 1)
        case let .automatic(minimum):
            let top = ChartData.niceCeiling(max(values.max() ?? 0, minimum))
            return ChartRange(lower: 0, upper: top)
        case let .symmetric(minimum):
            let largest = values.map { abs($0) }.max() ?? 0
            let top = ChartData.niceCeiling(max(largest, minimum))
            return ChartRange(lower: -top, upper: top)
        case let .automaticGigabytes(minimum):
            let gigabyte = 1_073_741_824.0
            let top = ChartData.niceCeiling(max(values.max() ?? 0, minimum) / gigabyte) * gigabyte
            return ChartRange(lower: 0, upper: top)
        case let .floating(step, minimumSpan):
            let finite = values.filter(\.isFinite)
            guard step > 0, let low = finite.min(), let high = finite.max() else {
                return ChartRange(lower: 0, upper: max(minimumSpan, 1))
            }
            var lower = max(0, (low / step).rounded(.down) * step)
            var upper = max((high / step).rounded(.up) * step, lower + step)
            // 폭이 모자라면 위아래로 번갈아 한 칸씩 넓혀요. (바닥은 0에서 멈춰요)
            var growUp = true
            while upper - lower < minimumSpan - 0.000_001 {
                if growUp || lower <= 0 {
                    upper += step
                } else {
                    lower -= step
                }
                growUp.toggle()
            }
            return ChartRange(lower: lower, upper: upper)
        case let .zeroAnchored(step, minimumSpan):
            let finite = values.filter(\.isFinite)
            let low = min(finite.min() ?? 0, 0)
            let high = max(finite.max() ?? 0, 0)
            guard step > 0 else {
                return ChartRange(lower: low, upper: max(high, low + 1))
            }
            var lower = (low / step).rounded(.down) * step
            var upper = (high / step).rounded(.up) * step
            // 폭이 모자라면 값이 있는 쪽으로 넓혀요. (방전만 하면 아래로, 그 밖에는 위로)
            while upper - lower < minimumSpan - 0.000_001 {
                if high <= 0 && low < 0 {
                    lower -= step
                } else {
                    upper += step
                }
            }
            return ChartRange(lower: lower, upper: upper)
        }
    }
}

/// 기록을 그래프용 점으로 바꾸는 계산이에요.
nonisolated enum ChartData {
    /// 범위 안의 기록을 시간 칸으로 묶어 평균을 내요. 기록이 없는 칸은 만들지 않아요.
    static func buckets(_ samples: [HistorySample], in window: ChartWindow) -> [ChartBucket] {
        var result: [ChartBucket] = []
        var currentIndex: Int?
        var dateSum = 0.0
        var sampleCount = 0
        var valueSum = 0.0
        var valueCount = 0

        func finishBucket() {
            guard let index = currentIndex, sampleCount > 0 else {
                return
            }
            result.append(ChartBucket(
                index: index,
                date: Date(timeIntervalSinceReferenceDate: dateSum / Double(sampleCount)),
                value: valueCount > 0 ? valueSum / Double(valueCount) : nil))
        }

        for sample in samples where window.contains(sample.date) {
            let offset = sample.date.timeIntervalSince(window.start) / window.bucketDuration
            let index = Int(offset.rounded(.down))
            if index != currentIndex {
                finishBucket()
                currentIndex = index
                dateSum = 0
                sampleCount = 0
                valueSum = 0
                valueCount = 0
            }
            dateSum += sample.date.timeIntervalSinceReferenceDate
            sampleCount += 1
            if let value = sample.value {
                valueSum += value
                valueCount += 1
            }
        }
        finishBucket()
        return result
    }

    /// 한 계열을 선 토막으로 나눠요. 값을 읽지 못한 칸이나 오래 빈 구간에서 선을 끊어요.
    static func lineRuns(_ samples: [HistorySample], in window: ChartWindow, maxGap: TimeInterval) -> [ChartRun] {
        var runs: [ChartRun] = []
        var points: [ChartPoint] = []
        var previousDate: Date?

        func finishRun() {
            if !points.isEmpty {
                runs.append(ChartRun(points: points))
                points = []
            }
        }

        for bucket in buckets(samples, in: window) {
            if let last = previousDate, bucket.date.timeIntervalSince(last) > maxGap {
                finishRun()
            }
            previousDate = bucket.date
            if let value = bucket.value {
                points.append(ChartPoint(date: bucket.date, value: value))
            } else {
                finishRun()
            }
        }
        finishRun()
        return runs
    }

    /// 여러 계열을 아래에서부터 쌓아요. 한 층이라도 값이 없는 칸에서는 모든 층을 함께 끊어요.
    static func stackedRuns(_ layers: [[HistorySample]], in window: ChartWindow, maxGap: TimeInterval) -> [StackedRun] {
        let bucketed = layers.map { buckets($0, in: window) }
        guard let base = bucketed.first else {
            return []
        }
        let lookups: [[Int: ChartBucket]] = bucketed.map { list in
            Dictionary(list.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        }

        var runs: [StackedRun] = []
        var points: [StackedPoint] = []
        var previousDate: Date?

        func finishRun() {
            if !points.isEmpty {
                runs.append(StackedRun(points: points))
                points = []
            }
        }

        for bucket in base {
            if let last = previousDate, bucket.date.timeIntervalSince(last) > maxGap {
                finishRun()
            }
            previousDate = bucket.date

            var tops: [Double] = []
            var total = 0.0
            for lookup in lookups {
                guard let value = lookup[bucket.index]?.value else {
                    break
                }
                total += value
                tops.append(total)
            }
            if tops.count == lookups.count {
                points.append(StackedPoint(date: bucket.date, tops: tops))
            } else {
                finishRun()
            }
        }
        finishRun()
        return runs
    }

    /// 보기 좋은 위쪽 선 값이에요. 1, 1.5, 2, 3, 4, 5, 6, 8, 10 × 10ⁿ 중 value 이상에서 가장 작은 값을 골라요.
    static func niceCeiling(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else {
            return 1
        }
        let magnitude = pow(10, floor(log10(value)))
        let steps: [Double] = [1, 1.5, 2, 3, 4, 5, 6, 8, 10]
        for step in steps where step * magnitude >= value * 0.999 {
            return step * magnitude
        }
        return 10 * magnitude
    }
}
