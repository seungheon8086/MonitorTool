import SwiftUI

/// 앱의 시작점이에요.
/// 메뉴 막대 앱이라 창을 띄우지 않고, 실제 동작(메뉴 막대 아이콘·패널·단축키·설정 창)은 AppDelegate가 맡아요.
@main
struct MonitorToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI 앱에는 장면(Scene)이 하나 이상 있어야 해요.
        // 설정 창은 AppDelegate가 직접 만든 창을 쓰고, 앱 메뉴의 '설정…'(⌘,)도 그 창을 열게 바꿔요.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("설정…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
