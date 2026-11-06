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
    /// 스냅숏 대신 이 값을 그대로 기록해요. (디스크 활성 시간처럼 기록 시각이 지금 값과 다른 계열)
    var values: [Metric: Double] = [:]
}

extension MetricBatch {
    nonisolated init(values: [Metric: Double], date: Date) {
        self.init(metrics: Array(values.keys), date: date, values: values)
    }
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
    /// 정한 계열만 그 시각으로 기록에 더해요. 정상이 아닌 값은 빈칸으로 남겨요.
    nonisolated mutating func record(_ metrics: [Metric], from snapshot: MonitorSnapshot, at date: Date) {
        for metric in metrics {
            append(MetricHistory.value(of: metric, in: snapshot), for: metric, at: date)
        }
        removeExpired(now: date)
    }

    /// 정해 준 값을 그 시각으로 기록에 더해요.
    nonisolated mutating func record(values: [Metric: Double], at date: Date) {
        for (metric, value) in values {
            append(value, for: metric, at: date)
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
        case .gpuMemory:
            return snapshot.gpu.memory.okValue
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
        case .diskRead(let id):
            return snapshot.disk.disks.okValue?.first { $0.id == id }?.read.okValue
        case .diskWrite(let id):
            return snapshot.disk.disks.okValue?.first { $0.id == id }?.write.okValue
        case .diskQueue(let id):
            return snapshot.disk.disks.okValue?.first { $0.id == id }?.queueDepth.okValue
        case .diskActive(let id):
            guard let disk = snapshot.disk.disks.okValue?.first(where: { $0.id == id }), !disk.activeEstimated else {
                return nil
            }
            return disk.active.okValue
        case .diskActiveEstimate(let id):
            guard let disk = snapshot.disk.disks.okValue?.first(where: { $0.id == id }), disk.activeEstimated else {
                return nil
            }
            return disk.active.okValue
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
