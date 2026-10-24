import Foundation

/// 기록 한 칸이에요. 그때 값을 읽지 못했으면 value가 nil이에요.
nonisolated struct HistorySample: Hashable, Sendable {
    var date: Date
    var value: Double?
}

/// 새로 잰 계열들과 잰 시각이에요. 수집기마다 재는 때가 달라서 묶음마다 따로 기록해요.
nonisolated struct MetricBatch: Sendable {
    var metrics: [Metric]
    var date: Date
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

    /// 정한 계열만 그 시각으로 기록에 더해요. 정상이 아닌 값은 빈칸으로 남겨요.
    nonisolated mutating func record(_ metrics: [Metric], from snapshot: MonitorSnapshot, at date: Date) {
        for metric in metrics {
            append(MetricHistory.value(of: metric, in: snapshot), for: metric, at: date)
        }
        removeExpired(now: date)
    }

    /// 스냅숏에서 한 계열의 값을 꺼내요. 정상 상태가 아니면 nil이에요. (위 record와 같은 규칙)
    nonisolated static func value(of metric: Metric, in snapshot: MonitorSnapshot) -> Double? {
        let memory = snapshot.memory
        let trafficRead = memory.trafficTotal.okValue != nil
        switch metric {
        case .cpuEfficiency:
            return snapshot.cpu.efficiencyUsage.okValue
        case .cpuPerformance:
            return snapshot.cpu.performanceUsage.okValue
        case .cpuPower:
            return snapshot.cpu.power.okValue
        case .gpuUsage:
            return snapshot.gpu.usage.okValue
        case .gpuPower:
            return snapshot.gpu.power.okValue
        case .anePower:
            return snapshot.ane.power.okValue
        case .aneTraffic:
            return snapshot.ane.dramTraffic.okValue
        case .memoryUsed:
            return memory.used.okValue
        case .traffic(let group):
            guard trafficRead else { return nil }
            switch group {
            case .cpu:
                return memory.traffic(of: .cpu)
            case .gpu:
                return memory.traffic(of: .gpu)
            case .ane:
                return memory.traffic(of: .ane)
            case .other:
                let otherDevices: [TrafficDevice] = [.display, .storage, .other]
                return otherDevices.compactMap { memory.traffic(of: $0) }.reduce(0, +)
            }
        case .cpuTemperature:
            return snapshot.thermal.cpuMax.okValue
        case .gpuTemperature:
            return snapshot.thermal.gpuMax.okValue
        case .fan(let id):
            return snapshot.thermal.fans.okValue?.first { $0.id == id }?.rpm.okValue
        case .batteryNetPower:
            return snapshot.battery.netPower.okValue
        case .networkDownload:
            return snapshot.network.download.okValue
        case .networkUpload:
            return snapshot.network.upload.okValue
        }
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
