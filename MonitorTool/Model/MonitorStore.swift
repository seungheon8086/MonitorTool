import Foundation
import Observation

/// 패널(나중에는 위젯도)이 보는 값을 모아 두는 곳이에요.
/// 값을 실제로 재는 수집기는 5단계(통합)에서 붙여요. 그 전까지 값은 모두 '준비 중'이에요.
@Observable
final class MonitorStore {
    var snapshot: MonitorSnapshot

    init(snapshot: MonitorSnapshot = MonitorSnapshot()) {
        self.snapshot = snapshot
    }
}
