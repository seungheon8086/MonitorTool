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
    /// 팬 제어 (패널 '팬 제어', 설정 창 '팬')
    private lazy var fanControl = FanControlModel(helper: helper)

    private var panelShortcut: PanelShortcut?
    private var panelController: PanelController?
    // periphery:ignore - 메뉴 막대 아이콘이 사라지지 않게 붙잡아 둬요.
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var collectionScheduler: CollectionScheduler?
    /// 위젯이 읽을 공유 파일을 써요. (docs/WIDGET_V2.md)
    private var widgetPublisher: WidgetPublisher?
    /// 패널이 열려 있는지 (팬 제어 상태를 물을지 정할 때 써요)
    private var panelIsShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단축키(기본 fn + Space)로 어디서든 패널을 열고 닫아요.
        // 설정 창 '일반'에서 켜고 끄고, 직접 정한 조합(기본 ⌃⌥M)으로 바꿀 수 있어요.
        let shortcut = PanelShortcut { [weak self] in
            self?.panelController?.toggle()
        }
        panelShortcut = shortcut

        let panelController = PanelController(store: store,
                                              appearance: appearance,
                                              shortcut: shortcut,
                                              fanControl: fanControl,
                                              openSettings: { [weak self] in self?.showSettings() },
                                              allowHelper: { [weak self] in self?.allowHelper() },
                                              openFanSettings: { [weak self] in self?.showSettings(tab: .fan) })
        self.panelController = panelController

        let statusItemController = StatusItemController(panelController: panelController,
                                                        openSettings: { [weak self] in self?.showSettings() })
        statusItemController.showShortcut(shortcut.menuShortcut)
        self.statusItemController = statusItemController

        // 단축키를 바꾸거나 끄면 메뉴 막대 메뉴의 표시도 바꿔요.
        shortcut.onChange = { [weak statusItemController, weak shortcut] in
            guard let shortcut else { return }
            statusItemController?.showShortcut(shortcut.menuShortcut)
        }
        // fn + Space인데 손쉬운 사용 허용이 아직 없으면 macOS의 허용 창을 한 번 띄워요.
        if !shortcut.activate(promptForPermission: true) {
            print("⚠️ \(shortcut.combo.displayText) 단축키를 등록하지 못했어요. 다른 앱이 같은 조합을 쓰고 있을 수 있어요.")
        }

        // 값을 모으기 시작해요. 패널이 열려 있으면 1초, 닫혀 있으면 항목에 따라 5·10·30초마다 모아요.
        let collectionScheduler = CollectionScheduler(store: store, helper: helper)
        panelController.onVisibilityChange = { [weak self, weak collectionScheduler] isShown in
            // 먼저 기억해야 패널을 열자마자 모을 때 팬 제어 상태도 함께 물어요.
            self?.panelIsShown = isShown
            collectionScheduler?.panelVisible = isShown
        }
        // 팬 제어 상태는 볼 수 있을 때만(패널이나 설정 창이 열려 있을 때) 시스템 값을 모을 때마다 보조 프로그램에 물어요.
        // 둘 다 닫혀 있으면 묻지 않고, 다시 열면 바로 물어요. (2026-11-04 자원 사용 측정 뒤)
        collectionScheduler.onSystemCollect = { [weak self] in
            guard let self, self.panelIsShown || self.settingsWindowController?.isOpen == true else { return }
            self.fanControl.refresh()
        }
        collectionScheduler.start()
        self.collectionScheduler = collectionScheduler

        // 값이 바뀌거나 색을 바꾸면 위젯 공유 파일을 써요. (10초에 한 번까지)
        let widgetPublisher = WidgetPublisher(store: store, appearance: appearance)
        store.onUpdate = { [weak widgetPublisher] in widgetPublisher?.storeDidUpdate() }
        appearance.onChange = { [weak widgetPublisher] in widgetPublisher?.publish() }
        widgetPublisher.start()
        self.widgetPublisher = widgetPublisher

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
        widgetPublisher?.stop()
    }

    /// 설정 창을 열어요. 처음 열 때 만들고, 그다음부터는 같은 창을 다시 보여줘요.
    /// - Parameter tab: 이 탭을 골라서 열어요. (nil이면 마지막에 보던 탭)
    func showSettings(tab: SettingsWindowController.Tab? = nil) {
        if settingsWindowController == nil, let panelShortcut {
            settingsWindowController = SettingsWindowController(appearance: appearance,
                                                                shortcut: panelShortcut,
                                                                loginItem: loginItem,
                                                                helper: helper,
                                                                fanControl: fanControl)
        }
        settingsWindowController?.show(tab: tab)
        // 닫혀 있는 동안은 팬 제어 상태를 묻지 않아서, 열 때 바로 물어요.
        fanControl.refresh()
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
