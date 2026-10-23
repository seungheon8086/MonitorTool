import SwiftUI

/// 설정 창 '일반' 탭: 패널 단축키와 로그인할 때 열기 (화면 시안 '설정 창 · 일반')
struct GeneralSettingsView: View {
    @Environment(LoginItemSettings.self) private var loginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(title: "패널 단축키")
            SettingsNote(text: "어디서든 이 단축키로 패널을 열고 닫아요.")
            SettingsBox {
                ShortcutRecorder()
            }

            SettingsSectionTitle(title: "시작")
                .padding(.top, 12)
            SettingsBox {
                LoginItemRow()
            }

            Text("바꾼 설정은 바로 적용돼요.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
        .frame(width: SettingsLayout.width, alignment: .leading)
        .onAppear {
            loginItem.refresh()
        }
    }
}

/// 단축키 칸이에요. 누르면 '새 단축키를 누르세요'로 바뀌고, 다음에 누른 조합이 새 단축키가 돼요.
struct ShortcutRecorder: View {
    @Environment(PanelShortcut.self) private var shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if shortcut.isRecording {
                        shortcut.cancelRecording()
                    } else {
                        shortcut.startRecording()
                    }
                } label: {
                    Text(shortcut.isRecording ? "새 단축키를 누르세요" : shortcut.combo.displayText)
                        .font(.system(size: 13))
                        .foregroundStyle(shortcut.isRecording ? Color.accentColor : Color.primary)
                        .frame(width: 180, height: 26)
                        .background(fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(fieldBorder, lineWidth: shortcut.isRecording ? 2 : 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("패널 단축키"))
                .accessibilityValue(Text(shortcut.combo.displayText))
                .accessibilityHint(Text("눌러서 새 단축키를 입력해요"))

                Button("기본값(⌃⌥M)으로") {
                    shortcut.resetToStandard()
                }
            }
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(shortcut.problem == nil ? Color.secondary : StatusColor.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hint: String {
        if let problem = shortcut.problem {
            return problem
        }
        if shortcut.isRecording {
            return "원하는 조합을 누르세요. Esc를 누르면 취소돼요."
        }
        return "칸을 누르고 새 조합을 누르면 바로 바뀌어요. ⌘·⌃·⌥ 중 하나 이상이 들어가야 해요."
    }

    private var fieldFill: Color {
        shortcut.isRecording ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.05)
    }

    private var fieldBorder: Color {
        shortcut.isRecording ? Color.accentColor : Color.primary.opacity(0.15)
    }
}

/// '로그인할 때 MonitorTool 열기' 스위치
struct LoginItemRow: View {
    @Environment(LoginItemSettings.self) private var loginItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("로그인할 때 MonitorTool 열기")
                    .font(.system(size: 13))
                detail
            }
            Spacer(minLength: 8)
            Toggle("로그인할 때 MonitorTool 열기", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var isOn: Binding<Bool> {
        Binding(get: { loginItem.isOn },
                set: { loginItem.setOn($0) })
    }

    /// 스위치 아래 설명 (허용이 필요하거나 실패하면 그 안내로 바뀌어요)
    @ViewBuilder
    private var detail: some View {
        if let problem = loginItem.problem {
            Text(problem)
                .font(.system(size: 11))
                .foregroundStyle(StatusColor.error)
                .fixedSize(horizontal: false, vertical: true)
        } else if loginItem.needsApproval {
            HStack(spacing: 6) {
                Text("시스템 설정의 로그인 항목에서 허용해야 켜져요.")
                    .font(.system(size: 11))
                    .foregroundStyle(StatusColor.warningText)
                Button("로그인 항목 열기") {
                    loginItem.openSystemSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        } else {
            Text("켜 두면 Mac에 로그인할 때 메뉴 막대에 바로 나타나요.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("일반") {
    GeneralSettingsView()
        .environment(PanelShortcut(action: {}))
        .environment(LoginItemSettings())
}
#endif
