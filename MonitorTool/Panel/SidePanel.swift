import AppKit

/// 알림 센터처럼 화면 오른쪽에 뜨는 패널 창이에요.
/// - 다른 앱의 포커스를 뺏지 않아요 (nonactivatingPanel)
/// - 그래도 키 입력은 받을 수 있어서 Esc로 닫을 수 있어요
/// - 모든 데스크톱(Space)과 전체 화면 앱 위에도 나타나요
final class SidePanel: NSPanel {
    /// Esc를 눌렀을 때 불려요.
    var onDismissRequest: (() -> Void)?
    /// 패널 바깥을 클릭해서 키 창 자리를 잃었을 때 불려요. (고정 중이면 닫지 않아요)
    var onFocusLost: (() -> Void)?

    static func make() -> SidePanel {
        let panel = SidePanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none  // 열고 닫는 애니메이션은 PanelController가 직접 해요.
        return panel
    }

    // 테두리 없는 창은 원래 키 창이 될 수 없어요. Esc를 받으려면 허용해야 해요.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == Self.escapeKeyCode {
            onDismissRequest?()
            return
        }
        super.sendEvent(event)
    }

    // 다른 앱이나 바탕화면을 클릭하면 키 창 자리를 잃어요. 그때 패널을 닫아요. (고정 중이 아니면)
    override func resignKey() {
        super.resignKey()
        onFocusLost?()
    }

    private static let escapeKeyCode: UInt16 = 53
}
