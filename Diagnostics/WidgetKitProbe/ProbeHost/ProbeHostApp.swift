import SwiftUI

/// WidgetKit 위젯(ProbeWidget)을 담고, 위젯이 읽을 데이터를 써 주는 진단용 앱이에요.
@main
struct ProbeHostApp: App {
    @State private var writer = SnapshotWriter()

    var body: some Scene {
        WindowGroup("WidgetKit 위젯 진단") {
            ProbeStatusView(writer: writer)
                .task { writer.start() }
        }
        .windowResizability(.contentSize)
    }
}

private struct ProbeStatusView: View {
    let writer: SnapshotWriter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WidgetKit 위젯 진단")
                .font(.title2.bold())
            Text("5초마다 공유 폴더(App Group)에 더미 값을 쓰고 위젯 갱신을 요청해요. 확인하는 동안 이 창을 열어 두세요.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("쓴 횟수")
                    Text("\(writer.sequence)").monospacedDigit()
                }
                GridRow {
                    Text("마지막으로 쓴 시각")
                    Text(writer.lastWrite?.formatted(date: .omitted, time: .standard) ?? "-").monospacedDigit()
                }
                GridRow {
                    Text("위젯 갱신 요청")
                    Text("\(writer.reloadRequests)회").monospacedDigit()
                }
            }

            if let error = writer.lastError {
                Text("공유 폴더 쓰기 실패: \(error)")
                    .foregroundStyle(.red)
            }

            Divider()

            Text("확인할 것").font(.headline)
            Text("1. 알림 센터 맨 아래 '위젯 편집'에서 'MonitorTool WidgetKit Probe'를 중간 또는 큰 크기로 추가하세요.")
            Text("2. 위젯에 표시된 '쓴 횟수·시각'이 이 창과 얼마나 차이 나는지 몇 분 동안 지켜보세요.")
            Text("3. 위젯의 '상세 보기' 버튼을 눌러 같은 크기 안에서 그래프 화면으로 바뀌는지 확인하세요.")
        }
        .padding(24)
        .frame(width: 540, alignment: .leading)
    }
}
