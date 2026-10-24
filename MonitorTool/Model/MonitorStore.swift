import Foundation
import Observation

/// 패널(나중에는 위젯도)이 보는 값을 모아 두는 곳이에요.
/// 지금은 네트워크와 보조 프로그램의 CPU·ANE 전력이 들어와요. 나머지 수집기는 5단계(통합)에서 붙여요.
@Observable
final class MonitorStore {
    /// 가장 최근에 잰 값
    private(set) var snapshot: MonitorSnapshot
    /// 그래프용 최근 30분 기록
    private(set) var history: MetricHistory

    init(snapshot: MonitorSnapshot = MonitorSnapshot(), history: MetricHistory = MetricHistory()) {
        self.snapshot = snapshot
        self.history = history
    }

    /// 새로 잰 값을 넘기면 화면 값과 모든 계열의 기록을 함께 바꿔요.
    func update(with newSnapshot: MonitorSnapshot) {
        snapshot = newSnapshot
        history.record(newSnapshot)
    }

    /// 화면 값을 바꾸고, 이번에 새로 잰 계열만 그 시각으로 기록에 더해요.
    /// 수집기마다 재는 때가 달라서(네트워크는 매번, 전력은 보조 프로그램의 표본이 올 때) 계열별로 따로 남겨요.
    func update(with newSnapshot: MonitorSnapshot, recording batches: [MetricBatch]) {
        snapshot = newSnapshot
        for batch in batches {
            history.record(batch.metrics, from: newSnapshot, at: batch.date)
        }
    }

    /// 값의 상태만 바뀌었을 때(예: 보조 프로그램을 껐을 때) 화면 값만 바꿔요.
    /// 새로 잰 값이 아니라서 그래프 기록에는 더하지 않아요.
    func replace(with newSnapshot: MonitorSnapshot) {
        snapshot = newSnapshot
    }
}
