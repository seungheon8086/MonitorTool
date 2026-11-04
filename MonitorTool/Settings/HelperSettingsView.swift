import Foundation
import SwiftUI

/// 설정 창 '보조 프로그램' 탭: 관리자 권한 보조 프로그램 켜기·허용·끄기 (화면 시안 '설정 창 · 보조 프로그램')
struct HelperSettingsView: View {
    @Environment(HelperController.self) private var helper

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(title: "관리자 권한 보조 프로그램")

            SettingsBox(spacing: 0, padding: 0) {
                HelperStatusRow()
            }

            Text("보조 프로그램은 macOS 로그인 항목에 표시됨. 프로그램 삭제 전 보조 프로그램 끄기 필요")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
        .frame(width: SettingsLayout.width, alignment: .leading)
        .onAppear {
            helper.refreshStatus()
        }
    }

}

/// 상태 한 줄: 색 점 · 상태 · 설명 · 단추 (시안의 꺼짐 / 허용 필요 / 동작 중 / 연결 실패)
private struct HelperStatusRow: View {
    @Environment(HelperController.self) private var helper

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            actionButton
        }
        .padding(12)
    }

    private var title: String {
        switch helper.status {
        case .unknown: "확인하는 중이에요"
        case .notRegistered: "꺼져 있어요"
        case .requiresApproval: "허용이 필요해요"
        case .enabled: "동작 중이에요"
        case .failed: "연결하지 못했어요"
        }
    }

    private var detail: String {
        if let message = helper.actionMessage {
            return message
        }
        switch helper.status {
        case .unknown: return "상태 확인"
        case .notRegistered: return "등록되지 않음. CPU/ANE 전력 측정 권한 필요"
        case .requiresApproval: return "허용 필요. 시스템 설정에서 허용 바람"
        case .enabled: return helper.latestSample == nil ? "데이터 수신 대기" : ""
        case .failed: return helper.problem ?? ""
        }
    }

    private var detailColor: Color {
        helper.actionMessage != nil || helper.status == .failed ? StatusColor.error : Color.secondary
    }

    private var dotColor: Color {
        switch helper.status {
        case .unknown, .notRegistered: Color.gray
        case .requiresApproval: Color.orange
        case .enabled: StatusColor.active
        case .failed: StatusColor.error
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch helper.status {
        case .unknown:
            EmptyView()
        case .notRegistered:
            Button("켜기") {
                helper.turnOn()
            }
            .buttonStyle(.borderedProminent)
        case .requiresApproval:
            Button("시스템 설정 열기") {
                helper.openSystemSettings()
            }
            .buttonStyle(.borderedProminent)
        case .enabled:
            Button("끄기") {
                helper.turnOff()
            }
            .disabled(helper.isBusy)
        case .failed:
            Button("다시 시도") {
                helper.retry()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#if DEBUG
#Preview("꺼짐") {
    HelperSettingsView()
        .environment(HelperController.preview(.notRegistered))
}

#Preview("허용 필요") {
    HelperSettingsView()
        .environment(HelperController.preview(.requiresApproval))
}

#Preview("동작 중") {
    HelperSettingsView()
        .environment(HelperController.preview(.enabled,
                                              sample: PowerSample(cpuMilliwatts: 924, aneMilliwatts: 0,
                                                                  interval: 1, measuredAt: Date())))
}

#Preview("연결 실패") {
    HelperSettingsView()
        .environment(HelperController.preview(.failed,
                                              problem: "보조 프로그램이 응답하지 않아요. 다시 시도해 보세요."))
}
#endif
