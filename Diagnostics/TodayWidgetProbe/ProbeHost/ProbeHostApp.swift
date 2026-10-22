import SwiftUI

/// 구형 Today 위젯 확장(ProbeWidget)을 담는 진단용 앱이에요.
/// 이 앱을 한 번 실행해야 macOS가 안에 든 확장을 등록해요.
@main
struct ProbeHostApp: App {
    var body: some Scene {
        WindowGroup("Today 위젯 진단") {
            ProbeInstructionsView()
        }
        .windowResizability(.contentSize)
    }
}

private struct ProbeInstructionsView: View {
    private let steps = [
        "터미널에서 등록 여부 확인: pluginkit -mAvvv -p com.apple.widget-extension",
        "알림 센터를 열고 맨 아래 '위젯 편집'에서 'MonitorTool Probe' 찾기",
        "보이면 추가한 뒤 '펼치기'를 눌러 위젯 높이가 늘어나는지 확인",
        "로그 확인: log show --last 10m --predicate 'eventMessage CONTAINS \"TodayWidgetProbe\"' --info",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("구형 Today 위젯 진단")
                .font(.title2.bold())
            Text("이 앱 안에 든 구형 위젯 확장이 이 Mac의 알림 센터에 나타나는지 확인해요.")
                .foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(width: 560, alignment: .leading)
    }
}
