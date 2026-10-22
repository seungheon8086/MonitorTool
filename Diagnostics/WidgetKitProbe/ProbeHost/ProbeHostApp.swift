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
            Text("5초마다 공유 폴더(App Group)에 더미 값을 쓰고 위젯 갱신을 요청해요. 확인하는 동안 이 앱을 끄지 마세요.")
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
                GridRow {
                    Text("이 앱의 상태")
                    Text(writer.hostIsActive ? "맨 앞 (활성)" : "뒤 (비활성)")
                }
            }

            if let error = writer.lastError {
                Text("공유 폴더 쓰기 실패: \(error)")
                    .foregroundStyle(.red)
            }

            Divider()

            Text("확인할 것").font(.headline)
            Text("1. 알림 센터 맨 아래 '위젯 편집'에서 'MonitorTool WidgetKit Probe'를 큰 크기로 추가하세요.")
            Text("2. 다른 앱이나 바탕화면을 클릭해서 이 앱을 뒤로 보내세요. '이 앱의 상태'가 '뒤 (비활성)'으로 바뀌어요.")
            Text("3. 10분쯤 다른 일을 하다가 알림 센터를 열어 위젯의 '최근 갱신 간격(초)'을 확인하세요.")
            Text("4. '상세 보기' 버튼을 눌러 그래프로 바뀌는지, 누른 직후 값이 이 창과 같아지는지 확인하세요.")
        }
        .padding(24)
        .frame(width: 560, alignment: .leading)
    }
}
