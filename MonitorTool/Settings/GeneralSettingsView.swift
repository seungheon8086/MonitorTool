import SwiftUI

/// 설정 창 '일반' 탭: 패널 단축키, 로그인할 때 열기, 네트워크 속도 단위 (화면 시안 '설정 창 · 일반')
/// 단축키는 켜고 끌 수 있고, fn + Space와 직접 정한 조합 중에서 골라요. (2026-10-25 사용자 결정)
struct GeneralSettingsView: View {
    @Environment(LoginItemSettings.self) private var loginItem
    @Environment(PanelShortcut.self) private var shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(title: "패널 단축키")
            SettingsNote(text: "전역 접근 단축키(fn + Space는 손쉬운 사용 허용 필요)")
            SettingsBox(spacing: 10) {
                ShortcutSettings()
            }

            SettingsSectionTitle(title: "시작")
                .padding(.top, 12)
            SettingsBox {
                LoginItemRow()
            }

            SettingsSectionTitle(title: "단위")
                .padding(.top, 12)
            SettingsBox {
                NetworkRateUnitRow()
            }
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
        }
    }

    @ViewBuilder
    private var status: some View {
        switch shortcut.fnState {
        case .active:
            EmptyView()
        case .needsPermission:
            VStack(alignment: .leading, spacing: 4) {
                Text("권한 필요: 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 MonitorTool 허용")
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
                Text("키 입력 수신 실패. 프로그램 재시작 필요")
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
            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(shortcut.problem == nil ? Color.secondary : StatusColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hint: String {
        if let problem = shortcut.problem {
            return problem
        }
        if shortcut.isRecording {
            return "Esc : 취소"
        }
        return ""
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
                Button("로그인 항목 열기") {
                    loginItem.openSystemSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
    }
}

/// 네트워크 속도 단위: MB/s │ Mbps (패널·위젯 모두, 누적량은 늘 바이트) (2026-11-20 사용자 결정)
struct NetworkRateUnitRow: View {
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("네트워크 속도")
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("네트워크 속도", selection: unit) {
                ForEach(NetworkRateUnit.allCases) { unit in
                    Text(unit.title)
                        .tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private var unit: Binding<NetworkRateUnit> {
        Binding(get: { appearance.networkRateUnit },
                set: { appearance.setNetworkRateUnit($0) })
    }
}

#if DEBUG
#Preview("일반") {
    GeneralSettingsView()
        .environment(PanelShortcut(action: {}))
        .environment(LoginItemSettings())
        .environment(AppearanceSettings())
}
#endif
