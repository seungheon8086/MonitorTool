import AppKit
import QuartzCore
import SwiftUI

/// 사이드 패널을 만들고, 화면 오른쪽에서 미끄러져 나오고 들어가게 해요.
final class PanelController {
    private let panel: SidePanel
    private(set) var isShown = false
    private var lastHiddenAt = Date.distantPast

    private let panelWidth: CGFloat = 380
    /// 화면 가장자리와 패널 사이 간격
    private let edgeInset: CGFloat = 10
    /// 열고 닫을 때 옆으로 움직이는 거리
    private let slideDistance: CGFloat = 120

    /// - Parameters:
    ///   - store: 패널이 보여줄 값
    ///   - appearance: 항목별 색 설정
    init(store: MonitorStore, appearance: AppearanceSettings) {
        panel = SidePanel.make()

        // Liquid Glass 위에 SwiftUI 화면(PanelView)을 올려요.
        let glassView = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        glassView.cornerRadius = 24

        let rootView = PanelView()
            .environment(store)
            .environment(appearance)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []  // SwiftUI 내용 크기가 패널 크기를 바꾸지 않게 해요.
        hostingView.frame = glassView.bounds
        hostingView.autoresizingMask = [.width, .height]

        glassView.contentView = hostingView
        panel.contentView = glassView

        panel.onDismissRequest = { [weak self] in
            self?.hide()
        }
    }

    func toggle() {
        if isShown {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !isShown else { return }
        // 바깥 클릭으로 막 닫힌 직후의 클릭(예: 메뉴 막대 아이콘)으로 곧바로 다시 열리지 않게 해요.
        guard Date.now.timeIntervalSince(lastHiddenAt) > 0.25 else { return }
        guard let screen = screenUnderMouse() else { return }

        isShown = true
        let panel = self.panel
        let finalFrame = shownFrame(on: screen)

        // 오른쪽으로 조금 비켜난 투명한 상태에서 시작해요.
        panel.setFrame(finalFrame.offsetBy(dx: slideDistance, dy: 0), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)  // 키 창이 돼야 Esc와 바깥 클릭을 알아챌 수 있어요.

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        lastHiddenAt = .now

        let panel = self.panel
        let finalFrame = panel.frame.offsetBy(dx: slideDistance, dy: 0)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            // 완료 콜백은 메인 스레드에서 불리지만 타입에 그 표시가 없어서, 컴파일러에게 직접 알려 줘요.
            MainActor.assumeIsolated {
                // 닫히는 도중에 다시 열렸다면 그대로 둬요.
                if !self.isShown {
                    panel.orderOut(nil)
                }
            }
        }
    }

    /// 마우스가 있는 화면 (못 찾으면 기본 화면)
    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    /// 메뉴 막대와 Dock을 뺀 영역의 오른쪽 끝에 붙인 패널 위치
    private func shownFrame(on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        return NSRect(x: area.maxX - panelWidth - edgeInset,
                      y: area.minY + edgeInset,
                      width: panelWidth,
                      height: area.height - edgeInset * 2)
    }
}
