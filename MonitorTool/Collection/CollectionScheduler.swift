import AppKit
import Darwin
import Foundation

/// 값을 언제 모을지 정해요. (설계 문서 4장)
/// 패널이 열려 있으면 모두 1초(배터리는 5초)마다 모아요.
/// 닫혀 있으면 네트워크는 5초, CPU·GPU 사용률·IOReport 값(GPU 전력, ANE 사용 중 여부, DRAM 트래픽)·메모리·온도·팬·디스크와
/// 보조 프로그램의 CPU·ANE 전력은 10초, 배터리는 30초마다 모아요. 깨어나면 바로 모두 다시 재요.
final class CollectionScheduler {
    private let store: MonitorStore
    private let helper: HelperController
    private let processors = ProcessorCollector()
    private let ioReport = IOReportCollector()
    private let memory = MemoryCollector()
    private let thermal = ThermalCollector()
    private let battery = BatteryCollector()
    private let network = NetworkCollector()
    private let disks = DiskCollector()
    /// 시스템 값을 모을 때마다 불러요. (패널이 열려 있으면 1초, 닫혀 있으면 10초) 팬 제어 상태를 다시 물어요.
    var onSystemCollect: (() -> Void)?
    private var timer: Timer?
    // periphery:ignore - 알림 관찰을 붙잡아 둬요.
    private var sleepObserver: (any NSObjectProtocol)?
    // periphery:ignore - 알림 관찰을 붙잡아 둬요.
    private var wakeObserver: (any NSObjectProtocol)?
    // periphery:ignore - 알림 관찰을 붙잡아 둬요.
    private var dayObserver: (any NSObjectProtocol)?
    /// 마지막으로 그래프 기록에 더한 전력 표본의 측정 시각 (같은 표본을 두 번 더하지 않으려고)
    private var lastRecordedSampleDate: Date?
    /// 네트워크 말고 나머지 시스템 값(CPU·GPU·메모리·온도·팬·전력)을 마지막으로 잰 때예요.
    /// 잠든 시간도 세는 시계(나노초)라서, 깨어나면 바로 다시 재요. 0이면 아직 재지 않았어요.
    private var lastSystemCollectAt: UInt64 = 0
    /// 온도·팬을 마지막으로 잰 때 (같은 시계)
    private var lastThermalCollectAt: UInt64 = 0

    /// 패널이 열려 있는지예요. 바뀌면 모으는 간격도 바꿔요.
    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            startTimer()
            // 패널을 열면 다음 차례를 기다리지 않고 바로 모두 새로 재요.
            if panelVisible {
                collect()
            }
        }
    }

    /// 타이머 간격 (초). 닫혀 있을 때는 가장 자주 재는 네트워크에 맞춰 5초예요.
    private var interval: TimeInterval {
        panelVisible ? 1 : 5
    }

    /// 닫혀 있을 때 시스템 값을 재는 간격이에요. 10초인데, 타이머가 조금 일찍 와도 되게 0.5초 여유를 둬요.
    private static let hiddenSystemInterval: UInt64 = 9_500_000_000
    /// 열려 있을 때 온도·팬을 재는 간격이에요. 2초인데, 같은 까닭으로 0.1초 여유를 둬요.
    private static let openThermalInterval: UInt64 = 1_900_000_000

    /// 보조 프로그램이 powermetrics를 돌리는 간격 (밀리초)
    private var helperIntervalMilliseconds: Int {
        panelVisible ? HelperConstants.panelOpenInterval : HelperConstants.panelClosedInterval
    }

    private static let processorMetrics: [Metric] = [.cpuEfficiency, .cpuPerformance, .gpuUsage, .gpuMemory]
    private static let memoryMetrics: [Metric] = [.memoryUsed]
    private static let batteryMetrics: [Metric] = [.batteryNetPower]
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
        disks.save()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // 메인 실행 루프에 붙인 타이머라 메인 스레드에서 불려요. 그 사실을 컴파일러에게 알려 줘요.
            MainActor.assumeIsolated {
                self?.collect()
            }
        }
        // 간격의 10%만큼 여유를 줘서 다른 타이머와 함께 깨어날 수 있게 해요. (전력 절약)
        timer.tolerance = interval * 0.1
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
                self?.disks.save()
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
        helper.refreshStatusIfDue(panelVisible: panelVisible)
        // 닫혀 있으면 네트워크만 매번(5초) 재고, 나머지 시스템 값은 10초마다 재요.
        let clock = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        let systemDue = panelVisible || lastSystemCollectAt == 0
            || clock &- lastSystemCollectAt >= CollectionScheduler.hiddenSystemInterval
        // 온도·팬은 SMC에 키를 20개쯤 묻느라 한 번에 5 ms쯤 걸려요(2026-10-25 이 Mac에서 잼).
        // 그래서 패널이 열려 있어도 2초마다 재요. (설계 문서 4장: 1–2초)
        let thermalDue = systemDue
            && (!panelVisible || clock &- lastThermalCollectAt >= CollectionScheduler.openThermalInterval)
        if systemDue {
            lastSystemCollectAt = clock
            if helper.status == .enabled || helper.status == .failed {
                // 답이 오면 helper.onChange → publishPower()가 불려요.
                helper.requestPower(intervalMilliseconds: helperIntervalMilliseconds)
            }
            onSystemCollect?()
        }

        let now = Date()
        var snapshot = store.snapshot
        var batches: [MetricBatch] = []
        if systemDue {
            // 바로 앞에 쟀으면(0.5초 안) CPU·GPU 사용률은 건너뛰고 앞의 값을 그대로 둬요.
            if processors.update(&snapshot, now: now) {
                batches.append(MetricBatch(metrics: CollectionScheduler.processorMetrics, date: now))
            }
            // GPU 전력, ANE 사용 중 여부, DRAM 트래픽도 0.5초 안에 다시 부르면 건너뛰어요.
            let ioReportMetrics = ioReport.update(&snapshot, now: now)
            if !ioReportMetrics.isEmpty {
                batches.append(MetricBatch(metrics: ioReportMetrics, date: now))
            }
            memory.update(&snapshot.memory, now: now)
            batches.append(MetricBatch(metrics: CollectionScheduler.memoryMetrics, date: now))
            if thermalDue {
                lastThermalCollectAt = clock
                // ANE 온도는 위에서 읽은 'ANE 사용 중'을 보고 정해요.
                batches.append(MetricBatch(metrics: thermal.update(&snapshot, now: now), date: now))
            }
            // 디스크는 열려 있으면 1초, 닫혀 있으면 다른 시스템 값과 같이 10초마다 재요.
            // 오늘 누적은 누적 카운터의 차이라서 간격이 길어도 빠지지 않아요.
            snapshot.disk = disks.collect(now: now)
            let diskMetrics = (snapshot.disk.disks.okValue ?? []).flatMap { disk -> [Metric] in
                [.diskRead(disk.id), .diskWrite(disk.id), .diskQueue(disk.id)]
            }
            batches.append(MetricBatch(metrics: diskMetrics, date: now))
        }
        // 배터리는 따로 5초(닫혀 있으면 30초)마다 재요. 잴 때가 아니어도 오래된 값은 '오래됨'으로 바꿔요.
        if battery.update(&snapshot.battery, now: now, panelVisible: panelVisible) {
            batches.append(MetricBatch(metrics: CollectionScheduler.batteryMetrics, date: now))
        }
        snapshot.network = network.collect(now: now)
        batches.append(MetricBatch(metrics: CollectionScheduler.networkMetrics, date: now))
        snapshot.takenAt = now
        // 새 답이 없어도 매번 전력 값을 정리해요. 오래된 표본은 여기서 '오래됨'으로 바뀌어요.
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
        guard helper.status == .enabled, let sample = helper.latestSample else {
            // 쓸 수 있는 표본이 없어요. 새로 잰 값이 아니라서 기록에는 더하지 않아요.
            let reading = readingWithoutSample()
            snapshot.cpu.power = reading
            snapshot.ane.power = reading
            return nil
        }
        // 표본 구간의 2.5배에 2초를 더한 시간(1초 표본은 4.5초, 10초 표본은 27초)보다 오래되면
        // 새 표본이 제때 오지 않은 거예요. 값은 '오래됨'으로 흐리게 보여주고 기록에는 더하지 않아요.
        // (닫혀 있을 때는 10초마다 묻고 표본도 10초 구간이라, 받은 표본이 20초쯤까지 오래될 수 있어요)
        // 패널을 막 닫았을 때는 마지막 1초 표본 다음에 10초 표본이 와요. 그래서 지금 부탁한 간격과
        // 표본 구간 중 긴 쪽을 기준으로 삼아, 닫은 직후의 1초 표본을 '오래됨'으로 보지 않아요.
        let expectedInterval = max(sample.interval, Double(helperIntervalMilliseconds) / 1000)
        let limit = expectedInterval * 2.5 + 2
        let now = Date()
        snapshot.cpu.power = watts(sample.cpuMilliwatts, at: sample.measuredAt).checkedFreshness(now: now, limit: limit)
        snapshot.ane.power = watts(sample.aneMilliwatts, at: sample.measuredAt).checkedFreshness(now: now, limit: limit)
        guard now.timeIntervalSince(sample.measuredAt) <= limit,
              sample.measuredAt != lastRecordedSampleDate else { return nil }
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

    /// mW를 W로 바꿔요. 값이 없으면 0이 아니라 '읽지 못함'으로 남겨요.
    private func watts(_ milliwatts: Double?, at date: Date) -> Reading<Double> {
        guard let milliwatts, milliwatts.isFinite, milliwatts >= 0 else {
            return .failed("powermetrics가 이 값을 주지 않았어요.")
        }
        return .ok(milliwatts / 1000, at: date)
    }
}
