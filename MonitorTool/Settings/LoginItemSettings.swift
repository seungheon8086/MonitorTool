import AppKit
import Observation
import ServiceManagement

/// '로그인할 때 MonitorTool 열기' 설정이에요. macOS 로그인 항목(SMAppService.mainApp)에 넣거나 빼요.
@Observable
final class LoginItemSettings {
    /// macOS가 알려 주는 지금 상태
    private(set) var status: SMAppService.Status
    /// 켜거나 끄지 못했을 때 보여줄 글
    private(set) var problem: String?

    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init() {
        status = SMAppService.mainApp.status
        // 시스템 설정에서 허용하고 돌아오면 상태가 바뀌어 있어요. 앱으로 돌아올 때마다 다시 읽어요.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// 켜져 있는지 (시스템 설정의 허용을 기다리는 중도 켠 것으로 봐요)
    var isOn: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// 시스템 설정에서 허용해야 하는지
    var needsApproval: Bool {
        status == .requiresApproval
    }

    func setOn(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            refresh()
            // 허용이 필요해서 실패한 거라면 오류가 아니라 허용 안내를 보여줘요.
            if on && needsApproval {
                problem = nil
                return
            }
            problem = on ? "켜지 못했어요. (\(error.localizedDescription))" : "끄지 못했어요. (\(error.localizedDescription))"
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// 시스템 설정의 로그인 항목 화면을 열어요.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
