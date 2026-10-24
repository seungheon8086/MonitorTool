import AppKit

/// 앱이 켜지면 메뉴 막대 아이콘, 사이드 패널, 전역 단축키를 준비하고 값을 모으기 시작해요.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 패널이 보여줄 값이에요. 수집 일정(CollectionScheduler)이 채워요.
    private let store = MonitorStore()
    /// 항목별 색 설정 (설정 창 '모양')
    private let appearance = AppearanceSettings()
    /// 로그인할 때 열기 설정 (설정 창 '일반')
    private let loginItem = LoginItemSettings()
    /// CPU·ANE 전력을 읽는 관리자 권한 보조 프로그램 (설정 창 '보조 프로그램')
    private let helper = HelperController()

    private var panelShortcut: PanelShortcut?
    private var panelController: PanelController?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var collectionScheduler: CollectionScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단축키(기본 ⌃⌥M)로 어디서든 패널을 열고 닫아요. 설정 창 '일반'에서 바꿀 수 있어요.
        let shortcut = PanelShortcut { [weak self] in
            self?.panelController?.toggle()
        }
        panelShortcut = shortcut

        let panelController = PanelController(store: store,
                                              appearance: appearance,
                                              shortcut: shortcut,
                                              openSettings: { [weak self] in self?.showSettings() },
                                              allowHelper: { [weak self] in self?.allowHelper() })
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

        // 값을 모으기 시작해요. 패널이 열려 있으면 1초, 닫혀 있으면 5초마다 모아요.
        let collectionScheduler = CollectionScheduler(store: store, helper: helper)
        panelController.onVisibilityChange = { [weak collectionScheduler] isShown in
            collectionScheduler?.panelVisible = isShown
        }
        collectionScheduler.start()
        self.collectionScheduler = collectionScheduler

        #if DEBUG
        // 개발 중에는 실행하자마자 패널을 띄워서 바로 확인할 수 있게 해요.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            panelController.show()
        }
        #endif
    }

    /// 앱을 끝낼 때(메뉴의 '종료' 등) 오늘 네트워크 누적을 저장해요.
    /// Xcode의 정지 단추로 끝내면 불리지 않아서, 마지막 저장(30초마다) 뒤의 양은 남지 않아요.
    func applicationWillTerminate(_ notification: Notification) {
        collectionScheduler?.stop()
    }

    /// 설정 창을 열어요. 처음 열 때 만들고, 그다음부터는 같은 창을 다시 보여줘요.
    /// - Parameter tab: 이 탭을 골라서 열어요. (nil이면 마지막에 보던 탭)
    func showSettings(tab: SettingsWindowController.Tab? = nil) {
        if settingsWindowController == nil, let panelShortcut {
            settingsWindowController = SettingsWindowController(appearance: appearance,
                                                                shortcut: panelShortcut,
                                                                loginItem: loginItem,
                                                                helper: helper)
        }
        settingsWindowController?.show(tab: tab)
    }

    /// 패널의 '보조 프로그램 허용하기' 단추: 켜고 시스템 설정의 허용 화면을 열어요.
    /// 켜지 못했으면 설정 창의 '보조 프로그램' 탭에서 이유를 보여줘요.
    private func allowHelper() {
        helper.allow()
        if helper.actionMessage != nil || helper.status == .failed {
            showSettings(tab: .helper)
        }
    }
}
