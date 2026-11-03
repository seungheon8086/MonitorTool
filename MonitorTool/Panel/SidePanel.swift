import AppKit
import SwiftUI

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

    // MARK: - 늘 활성 모습 (2026-11-03 사용자 요청)
    // Liquid Glass는 창이 활성이 아니면(고정한 채 다른 앱을 누르면) 더 뿌연 모습으로 바뀌어요.
    // 패널은 열려 있는 동안 늘 같은 모습이어야 해서, AppKit이 '활성 모습으로 그릴지' 물을 때 늘 그렇다고 답해요.
    // (AppKit 비공개 메서드를 덮어써요. 키 입력·포커스는 실제 상태 그대로예요)

    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }

    // MARK: - 둥근 창 모양 (2026-11-03 사용자 요청)
    // 창 서버는 이 모양으로 창 뒤 흐림과 그림자를 만들어요. 없으면 창 전체 사각형이 흐려져서
    // 둥근 유리 바깥 네 귀퉁이에 네모가 보여요. (Chromium·Electron이 테두리 없는 창에 쓰는 비공개 메서드)

    /// 패널 유리와 같은 모서리 반지름
    static let cornerRadius: CGFloat = 24

    @objc func _cornerMask() -> NSImage? {
        Self.cornerMaskImage
    }

    /// 부드러운(continuous) 둥근 모서리를 그린 늘어나는 그림. 모서리 부분만 그대로 두고 가운데를 늘려요.
    /// 창 서버가 다른 스레드에서 그림을 그릴 수도 있어서, 그리는 함수를 넘기지 않고 미리 비트맵으로 만들어 둬요.
    private static let cornerMaskImage: NSImage = {
        let radius = SidePanel.cornerRadius
        // continuous 곡선은 반지름의 약 1.53배 길이에서 휘기 시작해요. 그 부분이 모두 들어가게 여유를 둬요.
        let inset = ceil(radius * 1.6)
        let side = inset * 2 + 1
        let size = NSSize(width: side, height: side)
        let scale: CGFloat = 2
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(side * scale), pixelsHigh: Int(side * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return image
        }
        bitmap.size = size
        let path = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(origin: .zero, size: size))
            .cgPath
        let cgContext = context.cgContext
        cgContext.scaleBy(x: scale, y: scale)
        cgContext.setFillColor(NSColor.black.cgColor)
        cgContext.addPath(path)
        cgContext.fillPath()
        context.flushGraphics()
        image.addRepresentation(bitmap)
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }()
}
