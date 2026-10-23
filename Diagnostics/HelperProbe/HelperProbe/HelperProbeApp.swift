import SwiftUI

/// 관리자 권한 보조 프로그램(LaunchDaemon)을 등록하고, XPC로 말을 걸어 보는 진단 앱이에요.
@main
struct HelperProbeApp: App {
    @State private var model = HelperModel()

    var body: some Scene {
        WindowGroup("보조 프로그램 진단") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
