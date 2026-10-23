import Foundation
import Observation

/// 패널(나중에는 위젯도)이 보는 값을 모아 두는 곳이에요.
/// 값을 실제로 재는 수집기는 5단계(통합)에서 붙여요. 그 전까지 값은 모두 '준비 중'이에요.
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

    /// 수집기가 새로 잰 값을 넘기면 화면 값과 기록을 함께 바꿔요. (5단계에서 연결)
    func update(with newSnapshot: MonitorSnapshot) {
        snapshot = newSnapshot
        history.record(newSnapshot)
    }
}
