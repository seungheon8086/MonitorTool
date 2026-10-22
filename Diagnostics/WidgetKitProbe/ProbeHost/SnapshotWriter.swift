import AppKit
import Foundation
import Observation
import WidgetKit

/// 5초마다 공유 폴더에 더미 스냅샷을 쓰고 위젯 갱신을 요청해요.
/// 위젯이 실제로 얼마나 자주 새 값을 보여주는지 재기 위한 진단용이에요.
@MainActor
@Observable
final class SnapshotWriter {
    private(set) var sequence = 0
    private(set) var reloadRequests = 0
    private(set) var lastWrite: Date?
    private(set) var lastError: String?
    /// 마지막으로 쓸 때 이 앱이 맨 앞(활성)이었는지
    private(set) var hostIsActive = false

    @ObservationIgnored private var series: [Double] = []
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        writeAndRequestReload()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            // 메인 런 루프에 등록한 타이머라 메인 스레드에서 불려요.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.writeAndRequestReload()
            }
        }
    }

    private func writeAndRequestReload() {
        sequence += 1
        hostIsActive = NSApp.isActive
        series.append(Double.random(in: 10...90))
        if series.count > 60 {
            series.removeFirst(series.count - 60)
        }

        let snapshot = ProbeSnapshot(sequence: sequence,
                                     writtenAt: .now,
                                     reloadRequests: reloadRequests + 1,
                                     series: series,
                                     hostWasActive: hostIsActive)
        do {
            try ProbeShared.save(snapshot)
            lastWrite = snapshot.writtenAt
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        reloadRequests += 1
        WidgetCenter.shared.reloadAllTimelines()
    }
}
