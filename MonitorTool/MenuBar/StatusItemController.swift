import AppKit

/// 메뉴 막대 아이콘이에요.
/// 왼쪽 클릭은 패널 열기/닫기, 오른쪽 클릭(또는 ⌃클릭)은 메뉴를 보여줘요.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let panelController: PanelController

    init(panelController: PanelController) {
        self.panelController = panelController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        super.init()
        configureButton()
        configureMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                               accessibilityDescription: "MonitorTool") {
            image.isTemplate = true  // 메뉴 막대의 밝은/어두운 모양에 맞춰 색이 바뀌어요.
            button.image = image
        } else {
            button.title = "MT"
        }

        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureMenu() {
        let toggleItem = NSMenuItem(title: "패널 열기/닫기",
                                    action: #selector(togglePanel),
                                    keyEquivalent: "m")
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "MonitorTool 종료",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        guard isRightClick else {
            panelController.toggle()
            return
        }

        // 메뉴를 잠깐만 연결해서 띄워요. 계속 연결해 두면 왼쪽 클릭도 메뉴가 돼 버려요.
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }
}
