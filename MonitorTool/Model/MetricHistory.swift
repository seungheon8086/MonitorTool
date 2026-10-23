import Foundation

/// 기록 한 칸이에요. 그때 값을 읽지 못했으면 value가 nil이에요.
nonisolated struct HistorySample: Hashable, Sendable {
    var date: Date
    var value: Double?
}

/// 그래프용 최근 기록이에요. 메모리에만 최근 30분을 남기고, 앱을 끄면 사라져요. (설계 문서 4장)
/// 앱을 켜기 전 기록은 만들지 않고, 읽지 못한 값은 0이 아니라 빈칸(nil)으로 남겨요.
nonisolated struct MetricHistory: Sendable {
    /// 남겨 두는 시간 (30분)
    static let keepDuration: TimeInterval = 30 * 60

    /// 계열마다 오래된 것부터 쌓인 기록
    private var series: [Metric: [HistorySample]] = [:]

    init() {}

    /// 한 계열의 기록 (오래된 것부터)
    func samples(for metric: Metric) -> [HistorySample] {
        series[metric] ?? []
    }

    /// 값 하나를 더해요. 숫자로 쓸 수 없는 값(무한대·NaN)은 빈칸으로 남겨요.
    mutating func append(_ value: Double?, for metric: Metric, at date: Date) {
        let usable = value.flatMap { $0.isFinite ? $0 : nil }
        series[metric, default: []].append(HistorySample(date: date, value: usable))
    }

    /// 30분보다 오래된 기록을 지워요. 매번 조금씩 지우지 않고, 1분치가 더 쌓이면 한꺼번에 지워요.
    mutating func removeExpired(now: Date) {
        let limit = now.addingTimeInterval(-Self.keepDuration)
        for metric in Array(series.keys) {
            guard let oldest = series[metric]?.first, oldest.date < limit.addingTimeInterval(-60) else {
                continue
            }
            series[metric]?.removeAll { $0.date < limit }
        }
    }
}

extension MetricHistory {
    /// 새로 잰 값들을 기록에 더해요. 정상이 아닌 값은 빈칸으로 남겨서 그래프에서 선이 끊기게 해요.
    nonisolated mutating func record(_ snapshot: MonitorSnapshot) {
        let date = snapshot.takenAt ?? Date()

        append(snapshot.cpu.efficiencyUsage.okValue, for: .cpuEfficiency, at: date)
        append(snapshot.cpu.performanceUsage.okValue, for: .cpuPerformance, at: date)
        append(snapshot.cpu.power.okValue, for: .cpuPower, at: date)
        append(snapshot.gpu.usage.okValue, for: .gpuUsage, at: date)
        append(snapshot.gpu.power.okValue, for: .gpuPower, at: date)
        append(snapshot.ane.power.okValue, for: .anePower, at: date)
        append(snapshot.ane.dramTraffic.okValue, for: .aneTraffic, at: date)
        append(snapshot.memory.used.okValue, for: .memoryUsed, at: date)

        // 기기별 트래픽은 합계를 읽었을 때만 남겨요.
        let memory = snapshot.memory
        let trafficRead = memory.trafficTotal.okValue != nil
        append(trafficRead ? memory.traffic(of: .cpu) : nil, for: .traffic(.cpu), at: date)
        append(trafficRead ? memory.traffic(of: .gpu) : nil, for: .traffic(.gpu), at: date)
        append(trafficRead ? memory.traffic(of: .ane) : nil, for: .traffic(.ane), at: date)
        let otherDevices: [TrafficDevice] = [.display, .storage, .other]
        let otherTotal = otherDevices.compactMap { memory.traffic(of: $0) }.reduce(0, +)
        append(trafficRead ? otherTotal : nil, for: .traffic(.other), at: date)

        append(snapshot.thermal.cpuMax.okValue, for: .cpuTemperature, at: date)
        append(snapshot.thermal.gpuMax.okValue, for: .gpuTemperature, at: date)
        if let fans = snapshot.thermal.fans.okValue {
            for fan in fans {
                append(fan.rpm.okValue, for: .fan(fan.id), at: date)
            }
        } else {
            // 팬 목록을 읽지 못하면, 지금까지 그린 팬 선을 여기서 끊어요.
            for metric in series.keys.filter(\.isFan) {
                append(nil, for: metric, at: date)
            }
        }

        append(snapshot.battery.netPower.okValue, for: .batteryNetPower, at: date)
        append(snapshot.network.download.okValue, for: .networkDownload, at: date)
        append(snapshot.network.upload.okValue, for: .networkUpload, at: date)

        removeExpired(now: date)
    }

    /// 한 계열의 기간 평균이에요. 읽은 값만으로 계산하고, 하나도 없으면 nil이에요.
    nonisolated func average(for metric: Metric, from start: Date, to end: Date) -> Double? {
        var sum = 0.0
        var count = 0
        for sample in samples(for: metric) where sample.date >= start && sample.date <= end {
            if let value = sample.value {
                sum += value
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
