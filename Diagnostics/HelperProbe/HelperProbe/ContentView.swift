import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    let model: HelperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("관리자 권한 보조 프로그램 진단")
                .font(.title2.bold())
            Text("MonitorTool이 CPU·ANE 전력을 읽으려면 관리자 권한으로 도는 보조 프로그램이 필요해요. 이 앱은 개인 팀 서명으로 보조 프로그램을 등록하고, 앱과 값을 주고받을 수 있는지 확인해요.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("등록 상태")
                    Text(model.statusText)
                        .bold()
                }
                GridRow {
                    Text("앱 서명 상태")
                    Text(model.signingText)
                        .font(.callout.monospaced())
                }
            }

            HStack {
                Button("1. 등록") { model.register() }
                Button("시스템 설정 열기") { model.openSettings() }
                Button("상태 새로고침") { model.refreshStatus() }
            }
            HStack {
                Button("2. 누구 권한으로 도는지 묻기") { model.askIdentity() }
                Button("3. 전력 한 번 재기") { model.samplePower() }
            }
            HStack {
                Button("4. 등록 해제") { model.unregister() }
                Spacer()
                Button("기록 지우기") { model.clearLog() }
                Button("기록 복사") { model.copyLog() }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
        }
        .padding(24)
        .frame(width: 620, alignment: .leading)
        .task { model.refreshStatus() }
        // 시스템 설정에서 허용하고 돌아오면 상태를 다시 읽어요.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshStatus()
        }
    }
}
