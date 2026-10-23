import AppKit
import Carbon.HIToolbox

/// 앱이 켜지면 메뉴 막대 아이콘, 사이드 패널, 전역 단축키를 준비해요.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 패널이 보여줄 값이에요. 값을 재는 수집기는 5단계(통합)에서 붙여요.
    private let store = MonitorStore()
    /// 항목별 색 설정이에요. 설정 창(3-3)에서 바꿀 수 있게 할 거예요.
    private let appearance = AppearanceSettings()

    private var panelController: PanelController?
    private var statusItemController: StatusItemController?
    private var toggleHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelController = PanelController(store: store, appearance: appearance)
        self.panelController = panelController
        statusItemController = StatusItemController(panelController: panelController)

        // ⌃⌥M (Control + Option + M)로 어디서든 패널을 열고 닫아요.
        toggleHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: [.control, .option]) {
            panelController.toggle()
        }
        if toggleHotKey == nil {
            print("⚠️ ⌃⌥M 단축키를 등록하지 못했어요. 다른 앱이 같은 조합을 쓰고 있을 수 있어요.")
        }

        #if DEBUG
        // 개발 중에는 실행하자마자 패널을 띄워서 바로 확인할 수 있게 해요.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            panelController.show()
        }
        #endif
    }
}
