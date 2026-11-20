import AppKit
import Darwin
import Foundation

/// 값을 언제 모을지 정해요. (설계 문서 4장)
/// 패널이 열려 있으면 모두 1초(온도·팬은 2초, 배터리는 5초)마다 모아요.
/// 닫혀 있으면 네트워크·CPU·GPU 사용률·IOReport 값(GPU 전력, ANE 사용 중 여부, DRAM 트래픽)·메모리·온도·팬·디스크와
/// 보조 프로그램의 CPU·ANE 전력을 10초마다 한 번에 모으고, 배터리는 30초마다 모아요. 깨어나면 바로 모두 다시 재요.
/// (2026-11-04 자원 사용 측정 뒤 네트워크 5초 → 10초: 닫혀 있을 때 앱이 깨는 횟수를 절반으로)
/// 화면이 꺼져 있으면 패널이 열려 있어도 30초마다만 모으고 CPU·ANE 전력은 묻지 않아요. 화면이 켜지면 바로 다시 재요.
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
    // periphery:ignore - 알림 관찰을 붙잡아 둬요.
    private var screenSleepObserver: (any NSObjectProtocol)?
    // periphery:ignore - 알림 관찰을 붙잡아 둬요.
    private var screenWakeObserver: (any NSObjectProtocol)?
    /// 화면이 꺼져 있는지예요. 꺼져 있으면 아무도 보지 않아서 30초마다만 모으고,
    /// CPU·ANE 전력은 묻지 않아요. (보조 프로그램이 15초 뒤 powermetrics를 멈춰요)
    private var screensAsleep = false
    /// 마지막으로 그래프 기록에 더한 전력 표본의 측정 시각 (같은 표본을 두 번 더하지 않으려고)
    private var lastRecordedSampleDate: Date?
    /// 네트워크 말고 나머지 시스템 값(CPU·GPU·메모리·온도·팬·전력)을 마지막으로 잰 때예요.
    /// 잠든 시간도 세는 시계(나노초)라서, 깨어나면 바로 다시 재요. 0이면 아직 재지 않았어요.
    private var lastSystemCollectAt: UInt64 = 0
    /// 온도·팬을 마지막으로 잰 때 (같은 시계)
    private var lastThermalCollectAt: UInt64 = 0
    /// 디스크 활성 시간: 보조 프로그램의 누적값으로 %를 내고 드라이버 통계와 대조해요. (docs/DISK_ACTIVE_TIME.md)
    private var activeMeter = DiskActiveMeter()
    /// 디스크별로 그래프 기록에 마지막으로 더한 활성 시간이에요. 추적과 추정이 바뀌는 곳을 이으려고 둬요.
    private var lastActiveRecord: [UInt64: (date: Date, value: Double, traced: Bool)] = [:]
    /// 활성 시간 계열마다 마지막으로 더한 시각 (이음점을 시각 순서가 꼬이지 않을 때만 넣으려고)
    private var activeSeriesEnd: [Metric: Date] = [:]
    /// 추적과 추정 사이를 이을 때 두 점 사이의 최대 간격. 그래프가 선을 끊는 간격(10초 계열은 25초)과 같아요.
    private static let activeJoinLimit: TimeInterval = 25
    /// 보조 프로그램이 마지막으로 알린 추적 상태 (추정의 까닭을 출력하려고)
    private var lastDiskActivityState: DiskActivityState?
    private var lastOtherTool: String?
    /// 디스크별로 마지막으로 출력한 활성 시간 출처. 바뀔 때만 기록에 남겨요. (4.3: 까닭은 화면에 보이지 않음)
    private var activeSourceNote: [UInt64: String] = [:]

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

    /// 패널을 보고 있는지예요. 패널이 열려 있어도 화면이 꺼져 있으면 보지 않는 거예요.
    private var panelShown: Bool {
        panelVisible && !screensAsleep
    }

    /// 타이머 간격 (초). 패널을 보고 있으면 1초, 닫혀 있으면 10초, 화면이 꺼져 있으면 30초예요.
    private var interval: TimeInterval {
        if screensAsleep {
            return 30
        }
        return panelVisible ? 1 : 10
    }

    /// 닫혀 있을 때 시스템 값을 재는 간격이에요. 10초인데, 타이머가 조금 일찍 와도 되게 0.5초 여유를 둬요.
    private static let hiddenSystemInterval: UInt64 = 9_500_000_000
    /// 열려 있을 때 온도·팬을 재는 간격이에요. 2초인데, 같은 까닭으로 0.1초 여유를 둬요.
    private static let openThermalInterval: UInt64 = 1_900_000_000

    /// 보조 프로그램이 powermetrics를 돌리는 간격 (밀리초)
    private var helperIntervalMilliseconds: Int {
        panelShown ? HelperConstants.panelOpenInterval : HelperConstants.panelClosedInterval
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
        // 디스크 활성 누적값이 오면 새 추적 값을 바로 넣어요.
        helper.onDiskActivity = { [weak self] sample in
            self?.publishDiskActivity(sample)
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
        // 화면이 꺼지면 아무도 보지 않으니 쉬고, 켜지면 바로 다시 재요.
        screenSleepObserver = workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setScreensAsleep(true)
            }
        }
        screenWakeObserver = workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setScreensAsleep(false)
            }
        }
    }

    private func setScreensAsleep(_ asleep: Bool) {
        guard asleep != screensAsleep else { return }
        screensAsleep = asleep
        startTimer()
        if !asleep {
            collect()
        }
    }

    /// 한 번 모아요.
    private func collect() {
        helper.refreshStatusIfDue(panelVisible: panelShown)
        // 닫혀 있으면 타이머(10초)마다 모두 재요. 타이머가 조금 일찍 와도 되게 9.5초를 기준으로 봐요.
        let clock = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        let systemDue = panelShown || lastSystemCollectAt == 0
            || clock &- lastSystemCollectAt >= CollectionScheduler.hiddenSystemInterval
        // 온도·팬은 SMC에 키를 20개쯤 묻느라 한 번에 5 ms쯤 걸려요(2026-10-25 이 Mac에서 잼).
        // 그래서 패널이 열려 있어도 2초마다 재요. (설계 문서 4장: 1–2초)
        let thermalDue = systemDue
            && (!panelShown || clock &- lastThermalCollectAt >= CollectionScheduler.openThermalInterval)
        if systemDue {
            lastSystemCollectAt = clock
            // 화면이 꺼져 있으면 CPU·ANE 전력과 팬 제어 상태를 묻지 않아요.
            if !screensAsleep {
                if helper.status == .enabled || helper.status == .failed {
                    // 답이 오면 helper.onChange → publishPower()가 불려요.
                    helper.requestPower(intervalMilliseconds: helperIntervalMilliseconds)
                    // 디스크 활성 누적값도 같은 때 따로 물어요. 화면이 꺼져 있으면 묻지 않아서 보조 프로그램이 추적을 놓아요.
                    // (docs/DISK_ACTIVE_TIME.md 4.1)
                    helper.requestDiskActivity(intervalMilliseconds: helperIntervalMilliseconds)
                }
                onSystemCollect?()
            }
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
            // 디스크 활성 시간. 추적을 못 쓰는 동안(보조 프로그램이 꺼짐·설정에서 끔·화면이 꺼짐)은 추정이에요.
            if !diskActivityUsable {
                activeMeter.reset()
                lastDiskActivityState = nil
                lastOtherTool = nil
            }
            batches.append(contentsOf: applyActive(to: &snapshot.disk, now: now))
            let diskMetrics = (snapshot.disk.disks.okValue ?? []).flatMap { disk -> [Metric] in
                [.diskRead(disk.id), .diskWrite(disk.id), .diskQueue(disk.id)]
            }
            batches.append(MetricBatch(metrics: diskMetrics, date: now))
        }
        // 배터리는 따로 5초(닫혀 있으면 30초)마다 재요. 잴 때가 아니어도 오래된 값은 '오래됨'으로 바꿔요.
        if battery.update(&snapshot.battery, now: now, panelVisible: panelShown) {
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

    // MARK: - 디스크 활성 시간 (docs/DISK_ACTIVE_TIME.md 3.2 · 4장)

    /// 보조 프로그램의 추적 값을 쓸 수 있는지예요. 화면이 꺼져 있으면 묻지 않아서 추적을 놓아요. (4.1)
    private var diskActivityUsable: Bool {
        !screensAsleep && helper.diskActivityEnabled && (helper.status == .enabled || helper.status == .failed)
    }

    /// 보조 프로그램에서 디스크 활성 누적값이 왔을 때: 새 추적 값을 바로 화면과 그래프에 넣어요. (전력의 publishPower와 같은 자리)
    /// 대조용 드라이버 작업 수는 받은 순간에 읽어요. 그래야 보조 프로그램 값(마지막 1초 경계)과 0~1초만 어긋나요.
    private func publishDiskActivity(_ sample: DiskActivitySample) {
        guard diskActivityUsable else { return }
        lastDiskActivityState = sample.state
        lastOtherTool = sample.otherTool
        let moment = DiskActiveMoment(date: Date(),
                                      awake: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                                      monotonic: clock_gettime_nsec_np(CLOCK_MONOTONIC))
        let mismatchedBefore = activeMeter.mismatched
        let fresh = activeMeter.receive(sample, driverOps: disks.operationCounts(), at: moment)
        reportMismatch(from: mismatchedBefore, to: activeMeter.mismatched, present: Set(sample.disks.map(\.id)))
        guard !fresh.isEmpty else { return }
        var snapshot = store.snapshot
        guard var list = snapshot.disk.disks.okValue else { return }
        var batches: [MetricBatch] = []
        for index in list.indices {
            guard let value = fresh[list[index].id] else { continue }
            CollectionScheduler.setTraced(&list[index], value)
            batches.append(contentsOf: recordActive(list[index].id, value.percent, traced: true, at: value.date))
        }
        snapshot.disk.disks.value = list
        store.update(with: snapshot, recording: batches)
    }

    /// 디스크마다 활성 시간을 넣어요. 쓸 수 있는 추적 값이 있으면 그 값, 없으면 드라이버 통계로 낸 추정,
    /// 그것도 없으면 드라이버 통계의 상태(준비 중 등)예요. 추정은 지금 시각으로 그래프에 더해요. (추적 값은 받을 때 더했어요)
    private func applyActive(to disk: inout DiskSnapshot, now: Date) -> [MetricBatch] {
        guard var list = disk.disks.okValue else { return [] }
        let expectedInterval = Double(helperIntervalMilliseconds) / 1000
        var batches: [MetricBatch] = []
        for index in list.indices {
            let id = list[index].id
            if let value = activeMeter.tracedValue(for: id) {
                CollectionScheduler.setTraced(&list[index], value)
                reportActiveSource(list[index], "추적")
                // 전력과 같은 기준: 그 값의 구간과 지금 묻는 간격 중 긴 쪽의 2.5배에 2초를 더한 시간이 지나면 '오래됨'
                let limit = max(value.interval, expectedInterval) * 2.5 + 2
                list[index].active = list[index].active.checkedFreshness(now: now, limit: limit)
            } else if let queueDepth = list[index].queueDepth.okValue {
                // 추정 = 그 구간 평균 동시 요청을 100%에서 자른 값
                let estimate = min(max(queueDepth, 0), 1) * 100
                list[index].active = .ok(estimate, at: now)
                list[index].activeEstimated = true
                list[index].activeIOOnly = false
                reportActiveSource(list[index], "추정 (\(estimateReason(for: id)))")
                batches.append(contentsOf: recordActive(id, estimate, traced: false, at: now))
            } else {
                // 드라이버 통계도 아직 없어요. (연결 직후·깨어난 직후)
                list[index].active = Reading(value: nil, state: list[index].queueDepth.state, measuredAt: nil)
                list[index].activeEstimated = false
                list[index].activeIOOnly = false
                reportActiveSource(list[index], "준비 중")
            }
        }
        // 빠진 디스크의 이음 기록은 지워요.
        let ids = Set(list.map(\.id))
        lastActiveRecord = lastActiveRecord.filter { ids.contains($0.key) }
        activeSourceNote = activeSourceNote.filter { ids.contains($0.key) }
        activeSeriesEnd = activeSeriesEnd.filter { metric, _ in
            switch metric {
            case .diskActive(let id), .diskActiveEstimate(let id): ids.contains(id)
            default: false
            }
        }
        disk.disks.value = list
        return batches
    }

    /// 대조가 어긋나거나 다시 맞으면 출력으로 알려요. 추정의 까닭은 화면에 보이지 않아요. (4.3)
    /// 디스크의 활성 시간 출처(추적·추정과 까닭·준비 중)가 바뀌면 출력해요.
    private func reportActiveSource(_ disk: DiskReading, _ note: String) {
        guard activeSourceNote[disk.id] != note else { return }
        activeSourceNote[disk.id] = note
        AppLog.notice(.disk, "디스크 활성: \(disk.name) → \(note)")
    }

    /// 추적 값을 못 쓰는 까닭 (출력용)
    private func estimateReason(for id: UInt64) -> String {
        if !helper.diskActivityEnabled { return "설정에서 끔" }
        if screensAsleep { return "화면 꺼짐" }
        guard helper.status == .enabled || helper.status == .failed else { return "보조 프로그램 꺼짐" }
        if activeMeter.mismatched.contains(id) { return "대조 어긋남" }
        switch lastDiskActivityState {
        case .otherTool: return "다른 추적 도구" + (lastOtherTool.map { " \($0)" } ?? "")
        case .starting: return "추적 잡는 중"
        case .failed: return "추적 실패"
        case .off, nil: return "추적 값 기다리는 중"
        // 첫 답·회차 바뀜·잠든 구간·잃은 구간은 기준만 잡아요.
        case .tracing: return "기준 잡는 중"
        }
    }

    /// present는 이번 답에 있는 디스크예요. (빠진 디스크는 '맞음'으로 알리지 않아요)
    private func reportMismatch(from before: Set<UInt64>, to after: Set<UInt64>, present: Set<UInt64>) {
        guard before != after else { return }
        let names = Dictionary((store.snapshot.disk.disks.okValue ?? []).map { ($0.id, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        for id in after.subtracting(before).sorted() {
            AppLog.error(.disk, "디스크 활성: 대조 어긋남 → 추정 (\(names[id] ?? String(id)))")
        }
        for id in before.subtracting(after).intersection(present).sorted() {
            AppLog.notice(.disk, "디스크 활성: 대조 맞음 → 추적 (\(names[id] ?? String(id)))")
        }
    }

    private static func setTraced(_ disk: inout DiskReading, _ value: DiskActiveValue) {
        disk.active = .ok(value.percent, at: value.date)
        disk.activeEstimated = false
        disk.activeIOOnly = disk.isInternal && !value.flushTrim
    }

    /// 활성 시간 기록. 추적과 추정이 바뀌는 곳은 앞 점을 새 계열에도 넣어 선을 이어요. (4.3 '추적 구간과 이어서 그린다')
    private func recordActive(_ id: UInt64, _ value: Double, traced: Bool, at date: Date) -> [MetricBatch] {
        let metric: Metric = traced ? .diskActive(id) : .diskActiveEstimate(id)
        var batches: [MetricBatch] = []
        if let last = lastActiveRecord[id], last.traced != traced, last.date < date,
           date.timeIntervalSince(last.date) <= CollectionScheduler.activeJoinLimit,
           activeSeriesEnd[metric].map({ $0 < last.date }) ?? true {
            batches.append(MetricBatch(values: [metric: last.value], date: last.date))
        }
        if activeSeriesEnd[metric].map({ $0 < date }) ?? true {
            batches.append(MetricBatch(values: [metric: value], date: date))
            activeSeriesEnd[metric] = date
        }
        lastActiveRecord[id] = (date, value, traced)
        return batches
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
