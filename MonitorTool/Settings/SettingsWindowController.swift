import AppKit
import SwiftUI

/// 설정 창이에요. 메뉴 막대 앱이라 SwiftUI의 Settings 장면 대신 직접 만든 창을 써요.
/// 위쪽 도구 막대의 탭(일반·모양·보조 프로그램)으로 화면을 바꿔요. 위젯 탭은 위젯을 만들 때(6단계) 더해요.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// 설정 창의 탭 (왼쪽부터 차례대로)
    enum Tab: Int {
        case general
        case appearance
        case helper
    }

    private let window: NSWindow
    private let tabs: SettingsTabViewController
    private let shortcut: PanelShortcut

    init(appearance: AppearanceSettings, shortcut: PanelShortcut, loginItem: LoginItemSettings,
         helper: HelperController) {
        // super.init 전에는 self의 속성을 읽을 수 없어서, 지역 상수로 먼저 만들고 나중에 넣어요.
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(SettingsWindowController.tab(title: "일반", symbol: "gearshape",
                                                         content: GeneralSettingsView()
                                                            .environment(shortcut)
                                                            .environment(loginItem)))
        tabs.addTabViewItem(SettingsWindowController.tab(title: "모양", symbol: "paintpalette",
                                                         content: AppearanceSettingsView()
                                                            .environment(appearance)))
        tabs.addTabViewItem(SettingsWindowController.tab(title: "보조 프로그램", symbol: "lock",
                                                         content: HelperSettingsView()
                                                            .environment(helper)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false

        self.tabs = tabs
        self.window = window
        self.shortcut = shortcut
        super.init()

        window.delegate = self
        tabs.fitWindowToSelectedTab(animated: false)
        window.center()
    }

    /// 설정 창을 앞으로 가져와요. 메뉴 막대 앱은 먼저 앱을 활성화해야 창이 다른 앱 뒤에 숨지 않아요.
    /// - Parameter tab: 이 탭을 골라서 보여줘요. (nil이면 마지막에 보던 탭)
    func show(tab: Tab? = nil) {
        if let tab {
            tabs.selectedTabViewItemIndex = tab.rawValue
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 새 단축키를 기다리던 중에 창을 닫으면 원래 단축키로 돌아가요.
        shortcut.cancelRecording()
    }

    private static func tab<Content: View>(title: String, symbol: String, content: Content) -> NSTabViewItem {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// 탭을 바꾸거나 내용 높이가 바뀌면 창 크기를 그 탭에 맞춰요. 창 위쪽 끝은 그대로 둬요.
private final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindowToSelectedTab(animated: true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController === selectedController {
            fitWindowToSelectedTab(animated: false)
        }
    }

    func fitWindowToSelectedTab(animated: Bool) {
        guard let controller = selectedController, let window = view.window else { return }
        var size = controller.preferredContentSize
        if size.width <= 0 || size.height <= 0 {
            size = controller.view.fittingSize
        }
        guard size.width > 0, size.height > 0 else { return }

        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    private var selectedController: NSViewController? {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return nil }
        return tabViewItems[selectedTabViewItemIndex].viewController
    }
}
