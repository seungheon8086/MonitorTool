import Foundation
import SwiftUI

/// 설정 창 '보조 프로그램' 탭: 관리자 권한 보조 프로그램 켜기·허용·끄기 (화면 시안 '설정 창 · 보조 프로그램')
struct HelperSettingsView: View {
    @Environment(HelperController.self) private var helper

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(title: "관리자 권한 보조 프로그램")
            SettingsNote(text: "CPU·ANE 전력은 관리자 권한이 있어야 읽을 수 있어요. 앱 전체가 아니라 이 작은 보조 프로그램만 관리자 권한으로 돌아요.")
            SettingsBox(spacing: 0, padding: 0) {
                HelperStatusRow()
                if helper.status == .requiresApproval {
                    Divider()
                    ApprovalSteps()
                }
            }

            SettingsSectionTitle(title: "보조 프로그램이 하는 일")
                .padding(.top, 12)
            SettingsBox(spacing: 0, padding: 0) {
                ForEach(Array(HelperSettingsView.duties.enumerated()), id: \.offset) { index, duty in
                    if index > 0 {
                        Divider()
                    }
                    DutyRow(text: duty)
                }
            }

            Text("보조 프로그램은 macOS의 로그인 항목에 함께 나타나요. MonitorTool을 지우기 전에 여기서 꺼 주세요.")
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

    /// 시안의 '보조 프로그램이 하는 일' 목록 (패널을 닫았을 때의 간격도 함께 적었어요)
    private static let duties = [
        "powermetrics를 정해진 옵션으로만 실행해요. (CPU·GPU·ANE 전력, 1초 간격 · 패널을 닫아 두면 10초)",
        "같은 개발자 서명을 가진 MonitorTool하고만 연결해요.",
        "파일을 만들거나 시스템 설정을 바꾸지 않아요.",
        "끄면 바로 멈추고, CPU·ANE 전력은 '권한 필요'로 보여요.",
    ]
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
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
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
        case .unknown:
            return "macOS에 보조 프로그램 상태를 묻고 있어요."
        case .notRegistered:
            return "CPU·ANE 전력은 '권한 필요'로 보여요."
        case .requiresApproval:
            return "시스템 설정에서 한 번만 허용하면 계속 동작해요."
        case .enabled:
            guard let sample = helper.latestSample else {
                return "첫 값을 기다리는 중이에요."
            }
            let time = ValueFormat.clock(sample.measuredAt)
            if helper.intervalMilliseconds <= HelperConstants.panelOpenInterval {
                return "CPU·ANE 전력을 1초마다 받고 있어요. 마지막 값 \(time)"
            }
            return "패널이 닫혀 있어서 \(helper.intervalMilliseconds / 1000)초마다 받고 있어요. 마지막 값 \(time)"
        case .failed:
            return helper.problem ?? "보조 프로그램이 응답하지 않아요. 다시 시도해 보세요."
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

/// 허용하는 방법 (허용이 필요할 때만 보여요)
private struct ApprovalSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(ApprovalSteps.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let steps = [
        "'시스템 설정 열기'를 눌러요.",
        "로그인 항목의 '백그라운드에서 허용'에서 MonitorTool을 켜요.",
        "이 창으로 돌아오면 상태가 '동작 중'으로 바뀌어요.",
    ]
}

/// '하는 일' 한 줄 (초록 체크 표시와 설명)
private struct DutyRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StatusColor.active)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                                              sample: PowerSample(cpuMilliwatts: 924, gpuMilliwatts: 26,
                                                                  aneMilliwatts: 0, interval: 1,
                                                                  measuredAt: Date())))
}

#Preview("연결 실패") {
    HelperSettingsView()
        .environment(HelperController.preview(.failed,
                                              problem: "보조 프로그램이 응답하지 않아요. 다시 시도해 보세요."))
}
#endif
