import AppKit
import Foundation

/// 값을 언제 모을지 정해요. 패널이 열려 있으면 1초, 닫혀 있으면 5초마다 모아요. (설계 문서 4장)
/// 지금은 네트워크와 보조 프로그램의 CPU·ANE 전력을 모아요. 나머지 수집기는 5단계(통합)에서 여기에 붙여요.
final class CollectionScheduler {
    private let store: MonitorStore
    private let helper: HelperController
    private let network = NetworkCollector()
    private var timer: Timer?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?
    private var dayObserver: (any NSObjectProtocol)?
    /// 마지막으로 그래프 기록에 더한 전력 표본의 측정 시각 (같은 표본을 두 번 더하지 않으려고)
    private var lastRecordedSampleDate: Date?

    /// 패널이 열려 있는지예요. 바뀌면 모으는 간격도 바꿔요.
    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            startTimer()
            // 패널을 열면 다음 차례를 기다리지 않고 바로 새 값을 받아요.
            if panelVisible {
                collect()
            }
        }
    }

    /// 지금 모으는 간격 (초). 닫혀 있을 때는 네트워크에 맞춰 5초예요. (CPU·RAM·GPU는 10초여도 돼요)
    private var interval: TimeInterval {
        panelVisible ? 1 : 5
    }

    /// 보조 프로그램이 powermetrics를 돌리는 간격 (밀리초)
    private var helperIntervalMilliseconds: Int {
        panelVisible ? HelperConstants.panelOpenInterval : HelperConstants.panelClosedInterval
    }

    private static let networkMetrics: [Metric] = [.networkDownload, .networkUpload]
    private static let powerMetrics: [Metric] = [.cpuPower, .anePower]

    init(store: MonitorStore, helper: HelperController) {
        self.store = store
        self.helper = helper
        // 보조 프로그램에서 답이 오거나 상태가 바뀌면 전력 값을 새로 넣어요.
        helper.onChange = { [weak self] in
            self?.publishPower()
        }
    }

    /// 모으기를 시작해요. (앱이 켜질 때 한 번 불러요)
    func start() {
        observeSystemEvents()
        startTimer()
        collect()
    }

    /// 앱이 끝날 때 불러요. 오늘 누적을 저장해요.
    func stop() {
        timer?.invalidate()
        timer = nil
        network.save()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // 메인 실행 루프에 붙인 타이머라 메인 스레드에서 불려요. 그 사실을 컴파일러에게 알려 줘요.
            MainActor.assumeIsolated {
                self?.collect()
            }
        }
        // 다른 타이머와 함께 깨어날 수 있게 조금 여유를 줘서 전력을 아껴요.
        timer.tolerance = 0.1
        // 메뉴를 열거나 스크롤하는 동안에도 멈추지 않게 해요.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 잠들기·깨기·날짜 바뀜을 알아채요.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        // 잠들기 직전에 한 번 재고 저장해요. (잠든 사이에 전원이 꺼져도 그때까지의 누적은 남아요)
        sleepObserver = workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collect()
                self?.network.save()
            }
        }
        // 깨어나면 바로 다시 재요. 잠든 구간은 NetworkMeter가 두 시계를 비교해서 알아채요.
        wakeObserver = workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collect()
            }
        }
        // 자정이나 시간대 변경으로 날짜가 바뀌면 바로 한 번 재요. (날짜 경계 표본)
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collect()
            }
        }
    }

    /// 한 번 모아요.
    private func collect() {
        helper.refreshStatusIfDue()
        if helper.status == .enabled || helper.status == .failed {
            // 답이 오면 helper.onChange → publishPower()가 불려요.
            helper.requestPower(intervalMilliseconds: helperIntervalMilliseconds)
        }

        let now = Date()
        var snapshot = store.snapshot
        snapshot.network = network.collect(now: now)
        snapshot.takenAt = now
        var batches = [MetricBatch(metrics: CollectionScheduler.networkMetrics, date: now)]
        // 새 답이 없어도 매번 전력 값을 정리해요. 오래된 표본은 여기서 '측정 준비 중'으로 바뀌어요.
        if let sampleDate = applyPower(to: &snapshot) {
            batches.append(MetricBatch(metrics: CollectionScheduler.powerMetrics, date: sampleDate))
        }
        store.update(with: snapshot, recording: batches)
    }

    /// 보조 프로그램에서 답이 오거나 상태가 바뀌었을 때: 전력 값만 새로 넣어요.
    private func publishPower() {
        var snapshot = store.snapshot
        if let sampleDate = applyPower(to: &snapshot) {
            store.update(with: snapshot,
                         recording: [MetricBatch(metrics: CollectionScheduler.powerMetrics, date: sampleDate)])
        } else if snapshot != store.snapshot {
            store.replace(with: snapshot)
        }
    }

    /// 보조 프로그램 상태와 CPU·ANE 전력을 넣어요. 아직 그래프에 넣지 않은 새 표본이면 그 측정 시각을 돌려줘요.
    private func applyPower(to snapshot: inout MonitorSnapshot) -> Date? {
        snapshot.helper = helper.status
        guard helper.status == .enabled, let sample = helper.latestSample, isFresh(sample) else {
            // 쓸 수 있는 표본이 없어요. 새로 잰 값이 아니라서 기록에는 더하지 않아요.
            let reading = readingWithoutSample()
            snapshot.cpu.power = reading
            snapshot.ane.power = reading
            return nil
        }
        snapshot.cpu.power = watts(sample.cpuMilliwatts, at: sample.measuredAt)
        snapshot.ane.power = watts(sample.aneMilliwatts, at: sample.measuredAt)
        guard sample.measuredAt != lastRecordedSampleDate else { return nil }
        lastRecordedSampleDate = sample.measuredAt
        return sample.measuredAt
    }

    /// 쓸 수 있는 표본이 없을 때의 CPU·ANE 전력 상태
    private func readingWithoutSample() -> Reading<Double> {
        switch helper.status {
        case .unknown, .enabled:
            return .preparing
        case .notRegistered, .requiresApproval:
            return .permissionNeeded
        case .failed:
            return .failed(helper.problem ?? "보조 프로그램에 연결하지 못했어요.")
        }
    }

    /// 표본이 너무 오래되지 않았는지예요. 표본 구간의 2배에 2초를 더한 시간 안이면 써요.
    /// (패널을 열어 1초 간격으로 바뀌는 동안에는 직전의 10초 표본을 그대로 보여줘요)
    private func isFresh(_ sample: PowerSample) -> Bool {
        Date().timeIntervalSince(sample.measuredAt) <= sample.interval * 2 + 2
    }

    /// mW를 W로 바꿔요. 값이 없으면 0이 아니라 '읽지 못함'으로 남겨요.
    private func watts(_ milliwatts: Double?, at date: Date) -> Reading<Double> {
        guard let milliwatts, milliwatts.isFinite, milliwatts >= 0 else {
            return .failed("powermetrics가 이 값을 주지 않았어요.")
        }
        return .ok(milliwatts / 1000, at: date)
    }
}
