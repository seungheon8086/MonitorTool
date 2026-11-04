import AppKit
import Foundation
import WidgetKit

/// 위젯이 읽을 값을 App Group 공유 파일에 쓰고 위젯에 다시 그려 달라고 부탁해요. (docs/WIDGET_V2.md 4장)
/// 값이 바뀌어도 10초에 한 번까지만 써요. 색을 바꿀 때·잠들기 직전·앱이 끝날 때는 바로 써요.
final class WidgetPublisher {
    private let store: MonitorStore
    private let appearance: AppearanceSettings
    /// 값이 바뀌었을 때 다시 쓰기까지 기다리는 최소 시간 (초)
    private static let minimumInterval: TimeInterval = 10
    private var lastWrite = Date.distantPast
    private var appState: WidgetAppState = .running
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?
    /// 같은 실패를 출력 창에 계속 찍지 않으려고 기억해요.
    private var reportedFailure = false

    init(store: MonitorStore, appearance: AppearanceSettings) {
        self.store = store
        self.appearance = appearance
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appState = .sleeping
                self.publish()
            }
        }
        wakeObserver = workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appState = .running
                // 깨어난 뒤 첫 값은 기다리지 않고 바로 써요.
                self.lastWrite = .distantPast
            }
        }
        publish()
    }

    /// 앱이 끝날 때 '앱 꺼짐'을 남겨요.
    func stop() {
        appState = .quit
        publish()
        for observer in [sleepObserver, wakeObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// 값이 바뀔 때마다 불려요. 마지막으로 쓴 뒤 10초가 지났을 때만 써요.
    func storeDidUpdate() {
        guard Date().timeIntervalSince(lastWrite) >= WidgetPublisher.minimumInterval else { return }
        publish()
    }

    /// 지금 값을 바로 써요.
    func publish() {
        let now = Date()
        lastWrite = now
        let snapshot = store.snapshot
        let end = snapshot.takenAt ?? now
        var colors: [String: String] = [:]
        for item in MonitorItem.allCases {
            colors[item.rawValue] = appearance.color(for: item).rawValue
        }
        let payload = WidgetPayload(savedAt: now,
                                    appState: appState,
                                    snapshot: snapshot,
                                    colors: colors,
                                    series: WidgetPublisher.series(from: store.history, end: end))
        do {
            try WidgetSharedFile.write(payload)
            reportedFailure = false
            // 요약 위젯과 그래프 위젯 모두 같은 파일을 읽어서 한 번에 갱신을 부탁해요.
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            if !reportedFailure {
                reportedFailure = true
                print("⚠️ 위젯: 공유 파일을 쓰지 못함 (\(error.localizedDescription))")
            }
        }
    }

    /// 최근 10분 기록을 10초 칸 60개의 평균으로 줄여요. 값이 없는 칸은 nil이에요.
    private static func series(from history: MetricHistory, end: Date) -> [String: [Double?]] {
        let count = WidgetPayload.bucketCount
        let length = WidgetPayload.bucketSeconds
        let start = end.addingTimeInterval(-Double(count) * length)
        var result: [String: [Double?]] = [:]
        for key in WidgetSeriesKey.allCases {
            var sums = Array(repeating: 0.0, count: count)
            var counts = Array(repeating: 0, count: count)
            for sample in history.samples(for: metric(for: key)) {
                guard let value = sample.value, sample.date > start, sample.date <= end else { continue }
                let index = min(count - 1, max(0, Int((sample.date.timeIntervalSince(start) / length).rounded(.up)) - 1))
                sums[index] += value
                counts[index] += 1
            }
            var values: [Double?] = (0..<count).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil }
            // 재는 간격이 칸보다 긴 계열(배터리는 약 30초)이 점으로 흩어지지 않게, 패널 그래프와 같은 기준
            // (가장 느린 수집 간격의 2.5배) 안의 빈 칸은 앞 값으로 이어요. 그보다 긴 공백은 그대로 비워요.
            let maxGap = metric(for: key).slowestInterval * 2.5
            var lastFilled: Int?
            for index in 0..<count {
                if values[index] != nil {
                    lastFilled = index
                } else if let last = lastFilled, Double(index - last) * length <= maxGap {
                    values[index] = values[last]
                }
            }
            result[key.rawValue] = values
        }
        return result
    }

    private static func metric(for key: WidgetSeriesKey) -> Metric {
        switch key {
        case .cpuEfficiency: .cpuEfficiency
        case .cpuPerformance: .cpuPerformance
        case .gpuUsage: .gpuUsage
        case .cpuPower: .cpuPower
        case .gpuPower: .gpuPower
        case .anePower: .anePower
        case .cpuTemperature: .cpuTemperature
        case .gpuTemperature: .gpuTemperature
        case .networkDownload: .networkDownload
        case .networkUpload: .networkUpload
        case .fan0: .fan(0)
        case .fan1: .fan(1)
        case .batteryNetPower: .batteryNetPower
        }
    }
}
