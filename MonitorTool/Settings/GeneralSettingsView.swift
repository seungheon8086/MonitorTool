import SwiftUI

/// 설정 창 '일반' 탭: 패널 단축키와 로그인할 때 열기 (화면 시안 '설정 창 · 일반')
/// 단축키는 켜고 끌 수 있고, fn + Space와 직접 정한 조합 중에서 골라요. (2026-10-25 사용자 결정)
struct GeneralSettingsView: View {
    @Environment(LoginItemSettings.self) private var loginItem
    @Environment(PanelShortcut.self) private var shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(title: "패널 단축키")
            SettingsNote(text: "다른 앱을 쓰는 중에도 단축키로 패널을 열고 닫아요. 끄면 메뉴 막대 아이콘으로만 열어요.")
            SettingsBox(spacing: 10) {
                ShortcutSettings()
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
            // 시스템 설정에서 손쉬운 사용을 허용하고 돌아왔을 수 있어요.
            shortcut.refreshPermission()
        }
    }
}

/// 패널 단축키: 켜기·끄기 스위치와 fn + Space / 직접 정한 조합 고르기
struct ShortcutSettings: View {
    @Environment(PanelShortcut.self) private var shortcut

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("어디서든 단축키로 패널 열기")
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle("어디서든 단축키로 패널 열기", isOn: isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            ShortcutChoiceRow(title: "fn + Space",
                              isSelected: shortcut.kind == .fnSpace,
                              select: { shortcut.setKind(.fnSpace) }) {
                FnShortcutStatus()
            }
            ShortcutChoiceRow(title: "직접 정한 조합",
                              isSelected: shortcut.kind == .custom,
                              select: { shortcut.setKind(.custom) }) {
                ShortcutRecorder()
                    .disabled(shortcut.kind != .custom)
            }
        }
        .disabled(!shortcut.isEnabled)
        .opacity(shortcut.isEnabled ? 1 : 0.5)
    }

    private var isEnabled: Binding<Bool> {
        Binding(get: { shortcut.isEnabled },
                set: { shortcut.setEnabled($0) })
    }
}

/// 단축키 고르기의 한 줄: 동그라미 + 이름, 그 아래 설명이나 입력 칸
private struct ShortcutChoiceRow<Detail: View>: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(title)
                        .font(.system(size: 13))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            detail
                .padding(.leading, 22)
        }
    }
}

/// fn + Space 아래 글: 손쉬운 사용 허용 상태와 허용 단추
private struct FnShortcutStatus: View {
    @Environment(PanelShortcut.self) private var shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if shortcut.kind == .fnSpace && shortcut.isEnabled {
                status
            }
            Text("fn + Space를 받으려면 키보드 입력을 살펴야 해서 손쉬운 사용 허용이 필요해요. fn + Space인지만 확인하고, 다른 입력은 그대로 흘려보내며 아무것도 저장하지 않아요.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch shortcut.fnState {
        case .active:
            Label("손쉬운 사용 허용됨 · 어디서든 fn + Space로 패널을 열고 닫아요", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(StatusColor.active)
        case .needsPermission:
            VStack(alignment: .leading, spacing: 4) {
                Text("시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 MonitorTool을 허용해야 동작해요.")
                    .font(.system(size: 12))
                    .foregroundStyle(StatusColor.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("허용하기") {
                        shortcut.requestPermission()
                    }
                    Button("손쉬운 사용 설정 열기") {
                        shortcut.openAccessibilitySettings()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Text("손쉬운 사용에서 허용돼 있는데 키 입력을 받지 못했어요. MonitorTool을 다시 켜 보고, 그래도 안 되면 목록에서 MonitorTool을 지운 뒤 다시 허용해 주세요.")
                    .font(.system(size: 12))
                    .foregroundStyle(StatusColor.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button("손쉬운 사용 설정 열기") {
                    shortcut.openAccessibilitySettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        case .off:
            EmptyView()
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
