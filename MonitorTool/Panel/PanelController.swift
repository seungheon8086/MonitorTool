import AppKit
import Observation
import QuartzCore
import SwiftUI

/// 사이드 패널을 만들고, 화면 오른쪽에서 미끄러져 나오고 들어가게 해요.
final class PanelController {
    private let panel: SidePanel
    /// 고정 단추 상태 (머리글 오른쪽 위)
    let pin = PanelPin()
    /// 패널이 보여주는 값. 패널을 숨긴 동안에는 화면을 다시 그리지 않게 알려 줘요.
    private let store: MonitorStore
    private(set) var isShown = false
    private var lastHiddenAt = Date.distantPast

    private let panelWidth: CGFloat = 380
    /// 화면 가장자리와 패널 사이 간격
    private let edgeInset: CGFloat = 10
    /// 열고 닫을 때 옆으로 움직이는 거리
    private let slideDistance: CGFloat = 120

    /// 패널이 열리고 닫힐 때 불러요. (값을 모으는 간격을 바꿔요)
    var onVisibilityChange: ((Bool) -> Void)?

    /// - Parameters:
    ///   - store: 패널이 보여줄 값
    ///   - appearance: 항목별 색 설정
    ///   - shortcut: 패널 단축키 (머리글에 지금 단축키를 보여줘요)
    ///   - openSettings: 패널 아래 톱니 단추를 눌렀을 때 할 일
    ///   - allowHelper: 패널 아래 '보조 프로그램 허용하기' 단추를 눌렀을 때 할 일
    ///   - fanControl: 팬 제어 (온도·팬 펼침 아래 '팬 제어')
    ///   - openFanSettings: 팬 제어의 '프리셋 편집'을 눌렀을 때 할 일
    init(store: MonitorStore, appearance: AppearanceSettings, shortcut: PanelShortcut,
         fanControl: FanControlModel,
         openSettings: @escaping () -> Void, allowHelper: @escaping () -> Void,
         openFanSettings: @escaping () -> Void) {
        panel = SidePanel.make()
        self.store = store
        // 처음에는 숨겨져 있어요. 보이기 전에는 값이 바뀌어도 화면을 다시 그리지 않아요.
        store.isDisplayed = false

        // Liquid Glass 위에 SwiftUI 화면(PanelView)을 올려요.
        let glassView = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        glassView.cornerRadius = 24

        let rootView = PanelView(openSettings: openSettings, allowHelper: allowHelper,
                                 openFanSettings: openFanSettings)
            .environment(store)
            .environment(appearance)
            .environment(shortcut)
            .environment(fanControl)
            .environment(pin)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []  // SwiftUI 내용 크기가 패널 크기를 바꾸지 않게 해요.
        hostingView.frame = glassView.bounds
        hostingView.autoresizingMask = [.width, .height]

        glassView.contentView = hostingView
        panel.contentView = glassView

        panel.onDismissRequest = { [weak self] in
            self?.hide()
        }
        // 고정 중이면 바깥을 눌러도 닫지 않아요.
        panel.onFocusLost = { [weak self] in
            guard let self, !self.pin.isPinned else { return }
            self.hide()
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
        // 숨긴 동안 쌓인 값을 화면에 알리고, 그다음 수집 일정이 바로 새로 재요.
        store.isDisplayed = true
        onVisibilityChange?(true)
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
        onVisibilityChange?(false)
        // 이제부터는 값이 바뀌어도 숨긴 패널을 다시 그리지 않아요. (닫히는 동안에는 마지막 값 그대로예요)
        store.isDisplayed = false

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

/// 패널 고정 단추의 상태예요. 켜 두면 바깥을 눌러도 패널이 닫히지 않아요. 앱을 다시 켜도 남아요. (2026-11-03 사용자 요청)
@Observable
final class PanelPin {
    private(set) var isPinned: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPinned = defaults.bool(forKey: PanelPin.key)
    }

    func toggle() {
        isPinned.toggle()
        defaults.set(isPinned, forKey: PanelPin.key)
    }

    private static let key = "panelPinned"
}
