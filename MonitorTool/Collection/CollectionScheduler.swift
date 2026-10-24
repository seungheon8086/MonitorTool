import Foundation

/// 값을 언제 모을지 정해요. 패널이 열려 있으면 1초, 닫혀 있으면 10초마다 모아요. (설계 문서 4장)
/// 지금은 보조 프로그램이 보내는 CPU·ANE 전력만 모아요. 나머지 수집기는 5단계(통합)에서 여기에 붙여요.
final class CollectionScheduler {
    private let store: MonitorStore
    private let helper: HelperController
    private var timer: Timer?
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

    /// 지금 모으는 간격 (밀리초)
    private var intervalMilliseconds: Int {
        panelVisible ? HelperConstants.panelOpenInterval : HelperConstants.panelClosedInterval
    }

    init(store: MonitorStore, helper: HelperController) {
        self.store = store
        self.helper = helper
        // 보조 프로그램에서 답이 오거나 상태가 바뀌면 패널 값을 새로 만들어요.
        helper.onChange = { [weak self] in
            self?.publish()
        }
    }

    /// 모으기를 시작해요. (앱이 켜질 때 한 번 불러요)
    func start() {
        startTimer()
        collect()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Double(intervalMilliseconds) / 1000, repeats: true) { [weak self] _ in
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

    /// 한 번 모아요.
    private func collect() {
        helper.refreshStatusIfDue()
        if helper.status == .enabled || helper.status == .failed {
            // 답이 오면 helper.onChange → publish()가 한 번 더 불려요.
            helper.requestPower(intervalMilliseconds: intervalMilliseconds)
        }
        // 새 답이 없어도 매번 정리해요. 오래된 표본은 여기서 '측정 준비 중'으로 바뀌어요.
        publish()
    }

    /// 보조 프로그램 상태와 전력 값을 패널 값에 넣어요. 새 표본이면 그래프 기록에도 더해요.
    private func publish() {
        var snapshot = store.snapshot
        snapshot.helper = helper.status

        guard helper.status == .enabled, let sample = helper.latestSample, isFresh(sample) else {
            // 쓸 수 있는 표본이 없어요. 새로 잰 값이 아니라서 기록에는 더하지 않아요.
            let reading = readingWithoutSample()
            snapshot.cpu.power = reading
            snapshot.ane.power = reading
            // 지금은 전력만 재서, 전력 표본이 없으면 '측정 준비 중'으로 보여요. (5단계에서 다른 값과 함께 바뀌어요)
            snapshot.takenAt = nil
            if snapshot != store.snapshot {
                store.replace(with: snapshot)
            }
            return
        }

        snapshot.cpu.power = watts(sample.cpuMilliwatts, at: sample.measuredAt)
        snapshot.ane.power = watts(sample.aneMilliwatts, at: sample.measuredAt)
        snapshot.takenAt = sample.measuredAt
        if sample.measuredAt != lastRecordedSampleDate {
            lastRecordedSampleDate = sample.measuredAt
            store.update(with: snapshot)
        } else if snapshot != store.snapshot {
            store.replace(with: snapshot)
        }
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
