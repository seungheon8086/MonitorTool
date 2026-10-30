import Foundation
import Observation

/// 패널(나중에는 위젯도)이 보는 값을 모아 두는 곳이에요. 값은 수집 일정(CollectionScheduler)이 넣어요.
/// 패널을 숨긴 동안에는 값과 기록을 계속 쌓되 화면에는 알리지 않아서, 숨긴 패널이 다시 그려지지 않아요.
/// 패널이 다시 보이면 그때까지 쌓인 값을 한 번에 알려요. (설계 문서 4장: 패널이 닫히면 렌더링을 중단한다)
@Observable
final class MonitorStore {
    /// 화면에 바뀐 것을 알린 횟수예요. 화면은 이 번호가 바뀔 때만 다시 그려요.
    private var revision = 0
    @ObservationIgnored private var currentSnapshot: MonitorSnapshot
    @ObservationIgnored private var currentHistory: MetricHistory
    /// 값이 바뀔 때마다 불러요. 화면에 보이는지와 상관없어요. (위젯 공유 파일을 쓰는 WidgetPublisher)
    @ObservationIgnored var onUpdate: (() -> Void)?

    /// 화면에 보이는지예요. false인 동안 바뀐 값은 다시 true가 될 때 한 번에 알려요.
    /// 사이드 패널(PanelController)이 열고 닫을 때 바꿔요. 미리보기에서는 늘 true예요.
    @ObservationIgnored var isDisplayed = true {
        didSet {
            if isDisplayed, !oldValue {
                revision &+= 1
            }
        }
    }

    /// 가장 최근에 잰 값
    var snapshot: MonitorSnapshot {
        _ = revision
        return currentSnapshot
    }

    /// 그래프용 최근 30분 기록
    var history: MetricHistory {
        _ = revision
        return currentHistory
    }

    init(snapshot: MonitorSnapshot = MonitorSnapshot(), history: MetricHistory = MetricHistory()) {
        currentSnapshot = snapshot
        currentHistory = history
    }

    /// 새로 잰 값을 넘기면 화면 값과 모든 계열의 기록을 함께 바꿔요.
    func update(with newSnapshot: MonitorSnapshot) {
        currentSnapshot = newSnapshot
        currentHistory.record(newSnapshot)
        announce()
    }

    /// 화면 값을 바꾸고, 이번에 새로 잰 계열만 그 시각으로 기록에 더해요.
    /// 수집기마다 재는 때가 달라서(네트워크는 매번, 전력은 보조 프로그램의 표본이 올 때) 계열별로 따로 남겨요.
    func update(with newSnapshot: MonitorSnapshot, recording batches: [MetricBatch]) {
        currentSnapshot = newSnapshot
        for batch in batches {
            currentHistory.record(batch.metrics, from: newSnapshot, at: batch.date)
        }
        announce()
    }

    /// 값의 상태만 바뀌었을 때(예: 보조 프로그램을 껐을 때) 화면 값만 바꿔요.
    /// 새로 잰 값이 아니라서 그래프 기록에는 더하지 않아요.
    func replace(with newSnapshot: MonitorSnapshot) {
        currentSnapshot = newSnapshot
        announce()
    }

    /// 화면에 보일 때만 바뀐 것을 알려요.
    private func announce() {
        onUpdate?()
        if isDisplayed {
            revision &+= 1
        }
    }
}
