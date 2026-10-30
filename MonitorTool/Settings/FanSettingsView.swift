import AppKit
import SwiftUI

/// 설정 창 '팬' 탭: 고정 RPM 프리셋과 기본 복귀 시간 (화면 시안 '설정 창 · 팬', docs/FAN_CONTROL.md)
struct FanSettingsView: View {
    @Environment(FanControlModel.self) private var fan
    /// 편집 중인 프리셋 (id가 nil이면 새로 추가하는 중)
    @State private var editing: PresetDraft?
    @State private var holdSelection = FanHoldSelection(FanHold.standard)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle(title: "고정 RPM 프리셋")
            if fan.limits.isEmpty {
                SettingsNote(text: "이 Mac은 해당 기능을 지원하지 않음")
            } else {
                presetList
                SettingsSectionTitle(title: "기본 복귀 시간")
                    .padding(.top, 8)
                FanHoldPicker(selection: $holdSelection)
                SettingsNote(text: "시스템 제어 복귀: 시간 종료 · \(Int(FanControlLimits.temperatureLimit)) °C 이상 · 열 압력 상승 · 앱 종료 · 잠자기 · 다른 프로그램의 제어")
            }
        }
        .padding(20)
        .frame(width: SettingsLayout.width)
        .onAppear {
            holdSelection = FanHoldSelection(fan.defaultHold)
        }
        .onChange(of: holdSelection) { _, newValue in
            if let hold = newValue.hold {
                fan.setDefaultHold(hold)
            }
        }
    }

    private var presetList: some View {
        SettingsBox(spacing: 0, padding: 0) {
            if fan.presets.isEmpty && editing == nil {
                Text("프리셋 없음")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ForEach(Array(fan.presets.enumerated()), id: \.element.id) { index, preset in
                if index > 0 {
                    Divider()
                }
                if let draft = editing, draft.id == preset.id {
                    editor(for: draft)
                } else {
                    row(preset, index: index)
                }
            }
            if let draft = editing, draft.id == nil {
                if !fan.presets.isEmpty {
                    Divider()
                }
                editor(for: draft)
            }
            Divider()
            Button {
                editing = PresetDraft(id: nil, name: "",
                                      fans: FanDraft.drafts(fan.initialCustom, limits: fan.limits))
            } label: {
                Label("프리셋 추가", systemImage: "plus")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(editing == nil ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 12)
            .disabled(editing != nil)
        }
    }

    private func row(_ preset: FanPreset, index: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(FanText.targets(preset.targets))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button {
                fan.movePreset(id: preset.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0 || editing != nil)
            .accessibilityLabel(Text("\(preset.name) 위로"))
            Button {
                fan.movePreset(id: preset.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == fan.presets.count - 1 || editing != nil)
            .accessibilityLabel(Text("\(preset.name) 아래로"))
            Button("편집") {
                editing = PresetDraft(id: preset.id, name: preset.name,
                                      fans: FanDraft.drafts(preset.targets, limits: fan.limits))
            }
            .controlSize(.small)
            .disabled(editing != nil)
            Button("삭제", role: .destructive) {
                fan.deletePreset(id: preset.id)
            }
            .controlSize(.small)
            .disabled(editing != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func editor(for draft: PresetDraft) -> some View {
        PresetEditor(draft: Binding(get: { editing ?? draft }, set: { editing = $0 }),
                     limits: fan.limits,
                     onCancel: { editing = nil },
                     onSave: save)
    }

    private func save() {
        guard let draft = editing else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = draft.fans.map(\.target)
        guard !name.isEmpty, fan.isValid(targets) else { return }
        if let id = draft.id {
            fan.updatePreset(FanPreset(id: id, name: name, targets: targets))
        } else {
            fan.addPreset(name: name, targets: targets)
        }
        editing = nil
    }
}

/// 편집 중인 프리셋
struct PresetDraft: Hashable {
    /// 고치는 프리셋의 id (새로 추가하면 nil)
    var id: UUID?
    var name: String
    var fans: [FanDraft]
}

/// 프리셋 편집: 이름 · 팬마다 정지·RPM · 취소·저장
private struct PresetEditor: View {
    @Binding var draft: PresetDraft
    let limits: [FanLimit]
    let onCancel: () -> Void
    let onSave: () -> Void

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.fans.count == limits.count
            && zip(limits, draft.fans).allSatisfy { $0.accepts($1.target) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("이름")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("예: 게임할 때", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            ForEach(limits.indices, id: \.self) { index in
                if draft.fans.indices.contains(index) {
                    FanDraftEditor(limit: limits[index], count: limits.count, draft: $draft.fans[index])
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("취소", action: onCancel)
                Button("저장", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.05))
    }
}

#if DEBUG
#Preview("팬") {
    FanSettingsView()
        .environment(FanControlModel.preview())
}
#endif
