import SwiftUI

/// 앱의 시작점이에요.
/// 메뉴 막대 앱이라 창을 띄우지 않고, 실제 동작(메뉴 막대 아이콘·패널·단축키)은 AppDelegate가 맡아요.
@main
struct MonitorToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI 앱에는 장면(Scene)이 하나 이상 있어야 해요.
        // 설정 창은 8단계에서 채울 예정이라 지금은 자리만 만들어 둬요.
        Settings {
            Text("설정은 8단계에서 추가돼요.")
                .padding(40)
        }
    }
}
