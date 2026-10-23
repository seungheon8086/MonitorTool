import AppKit

/// 앱이 켜지면 메뉴 막대 아이콘, 사이드 패널, 전역 단축키를 준비해요.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 패널이 보여줄 값이에요. 값을 재는 수집기는 5단계(통합)에서 붙여요.
    private let store = MonitorStore()
    /// 항목별 색 설정 (설정 창 '모양')
    private let appearance = AppearanceSettings()
    /// 로그인할 때 열기 설정 (설정 창 '일반')
    private let loginItem = LoginItemSettings()

    private var panelShortcut: PanelShortcut?
    private var panelController: PanelController?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단축키(기본 ⌃⌥M)로 어디서든 패널을 열고 닫아요. 설정 창 '일반'에서 바꿀 수 있어요.
        let shortcut = PanelShortcut { [weak self] in
            self?.panelController?.toggle()
        }
        panelShortcut = shortcut

        let panelController = PanelController(store: store,
                                              appearance: appearance,
                                              shortcut: shortcut,
                                              openSettings: { [weak self] in self?.showSettings() })
        self.panelController = panelController

        let statusItemController = StatusItemController(panelController: panelController,
                                                        openSettings: { [weak self] in self?.showSettings() })
        statusItemController.showShortcut(shortcut.combo)
        self.statusItemController = statusItemController

        // 단축키를 바꾸면 메뉴 막대 메뉴의 표시도 바꿔요.
        shortcut.onChange = { [weak statusItemController] combo in
            statusItemController?.showShortcut(combo)
        }
        if !shortcut.activate() {
            print("⚠️ \(shortcut.combo.displayText) 단축키를 등록하지 못했어요. 다른 앱이 같은 조합을 쓰고 있을 수 있어요.")
        }

        #if DEBUG
        // 개발 중에는 실행하자마자 패널을 띄워서 바로 확인할 수 있게 해요.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            panelController.show()
        }
        #endif
    }

    /// 설정 창을 열어요. 처음 열 때 만들고, 그다음부터는 같은 창을 다시 보여줘요.
    func showSettings() {
        if settingsWindowController == nil, let panelShortcut {
            settingsWindowController = SettingsWindowController(appearance: appearance,
                                                                shortcut: panelShortcut,
                                                                loginItem: loginItem)
        }
        settingsWindowController?.show()
    }
}
