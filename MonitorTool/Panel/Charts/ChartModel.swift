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
    case fixed(Double, midline: Bool)
    /// 보이는 값에 맞춰 보기 좋은 위쪽 선을 고르되, 적어도 minimum은 둬요.
    case automatic(minimum: Double)
    /// 0을 가운데 두고 위아래로 같은 폭이에요. (배터리 순전력: 위는 충전, 아래는 방전)
    case symmetric(minimum: Double)
    /// 바이트 값을 GB(1024³) 단위로 보기 좋은 위쪽 선에 맞춰요. 적어도 minimum(바이트)은 둬요. (GPU 메모리)
    case automaticGigabytes(minimum: Double)
}

/// 계산을 마친 세로 범위예요.
nonisolated struct ChartRange: Hashable, Sendable {
    var lower: Double
    var upper: Double
    /// 가운데 선 (없으면 nil). 대칭 그래프에서는 0 선이에요.
    var midline: Double?

    var isSymmetric: Bool {
        lower < 0
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
            return ChartRange(lower: 0, upper: 100, midline: 50)
        case let .fixed(upper, midline):
            let top = upper > 0 ? upper : 1
            return ChartRange(lower: 0, upper: top, midline: midline ? top / 2 : nil)
        case let .automatic(minimum):
            let top = ChartData.niceCeiling(max(values.max() ?? 0, minimum))
            return ChartRange(lower: 0, upper: top, midline: nil)
        case let .symmetric(minimum):
            let largest = values.map { abs($0) }.max() ?? 0
            let top = ChartData.niceCeiling(max(largest, minimum))
            return ChartRange(lower: -top, upper: top, midline: 0)
        case let .automaticGigabytes(minimum):
            let gigabyte = 1_073_741_824.0
            let top = ChartData.niceCeiling(max(values.max() ?? 0, minimum) / gigabyte) * gigabyte
            return ChartRange(lower: 0, upper: top, midline: nil)
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
