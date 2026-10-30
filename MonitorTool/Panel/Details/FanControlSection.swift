import AppKit
import SwiftUI

/// 패널 온도·팬 펼침 아래 '팬 제어' (화면 시안 '패널 · 온도·팬 펼침 + 팬 제어', docs/FAN_CONTROL.md)
/// 프리셋이나 직접 정한 값을 고르고 복귀 시간과 함께 적용해요. 실제 쓰기와 안전장치는 보조 프로그램이 해요.
struct FanControlSection: View {
    @Environment(FanControlModel.self) private var fan
    /// '프리셋 편집': 설정 창 '팬' 탭 열기
    let openFanSettings: () -> Void
    /// '허용하기': 보조 프로그램 켜기·허용
    let allowHelper: () -> Void

    /// 사용자가 고른 값. nil이면 지금 상태를 따라가요. (시스템 제어 · 고정 중인 프리셋 · 직접 정하기)
    @State private var choice: Choice?
    @State private var customDrafts: [FanDraft] = []
    @State private var holdSelection = FanHoldSelection(FanHold.standard)
    @State private var didLoad = false

    enum Choice: Hashable {
        case system
        case preset(UUID)
        case custom
    }

    var body: some View {
        DetailCard(title: "팬 제어") {
            if !fan.limits.isEmpty {
                Button("프리셋 편집", action: openFanSettings)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        } content: {
            if fan.limits.isEmpty {
                Text("이 Mac은 해당 기능을 지원하지 않음")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                FanStatusBox(allowHelper: allowHelper)
                if fan.isAvailable {
                    controls
                }
                SourceNote(text: "\(Int(FanControlLimits.temperatureLimit)) °C 이상·열 압력 상승·앱 종료·잠자기 시 시스템 제어 복귀")
            }
        }
        .onAppear(perform: loadOnce)
        // 적용·시간 종료·안전장치 복귀로 상태가 바뀌면 고른 항목도 다시 상태를 따라가요.
        .onChange(of: fan.active) { _, _ in
            choice = nil
        }
    }

    // MARK: - 고르기·적용

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("적용 값")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            choicePicker
        }

        if selectedChoice == .custom {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fan.limits.indices, id: \.self) { index in
                    if customDrafts.indices.contains(index) {
                        FanDraftEditor(limit: fan.limits[index], count: fan.limits.count,
                                       draft: $customDrafts[index])
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        if selectedChoice != .system {
            VStack(alignment: .leading, spacing: 6) {
                Text("복귀 시간")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                FanHoldPicker(selection: $holdSelection)
            }
        }

        Button(action: apply) {
            Text(applyTitle)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canApply)

        if let problem = fan.problem {
            Text(problem)
                .font(.system(size: 12))
                .foregroundStyle(StatusColor.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 고를 수 있는 항목 수가 이보다 많으면 라디오 대신 팝업 메뉴로 보여요. (HIG: 라디오 버튼은 2~5개)
    private static let radioLimit = 5

    /// 표준 Picker: 5개 이하면 라디오 그룹, 그보다 많으면 팝업 메뉴 (2026-10-30 사용자 결정, 시안 A안)
    @ViewBuilder
    private var choicePicker: some View {
        let selection = Binding<Choice>(get: { selectedChoice }, set: { choice = $0 })
        if fan.presets.count + 2 <= Self.radioLimit {
            // 모든 항목을 '이름 + 작은 회색 한 줄'로 맞춰 간격을 같게 해요. (2026-10-30 사용자 요청)
            Picker("적용 값", selection: selection) {
                choiceLabel("시스템 제어", detail: "macOS 자동 조절")
                    .tag(Choice.system)
                ForEach(fan.presets) { preset in
                    choiceLabel(preset.name, detail: FanText.targets(preset.targets))
                        .tag(Choice.preset(preset.id))
                }
                choiceLabel("직접 정하기", detail: FanText.targets(customDrafts.map(\.target)))
                    .tag(Choice.custom)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Picker("적용 값", selection: selection) {
                    Text("시스템 제어").tag(Choice.system)
                    Divider()
                    ForEach(fan.presets) { preset in
                        Text(preset.name).tag(Choice.preset(preset.id))
                    }
                    Divider()
                    Text("직접 정하기").tag(Choice.custom)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                if case .preset(let id) = selectedChoice, let preset = fan.presets.first(where: { $0.id == id }) {
                    Text(FanText.targets(preset.targets))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.leading, 2)
                }
            }
        }
    }

    /// 라디오 항목: 이름 + 작은 회색 한 줄
    private func choiceLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 고른 값. 고르지 않았거나 고른 프리셋이 지워졌으면 지금 상태를 따라가요.
    private var selectedChoice: Choice {
        if let choice {
            if case .preset(let id) = choice, !fan.presets.contains(where: { $0.id == id }) {
                return currentChoice
            }
            return choice
        }
        return currentChoice
    }

    /// 지금 상태에 맞는 항목: 시스템 제어 · 고정 중인 프리셋(이름과 값이 같은 것) · 직접 정하기
    private var currentChoice: Choice {
        guard let active = fan.active else { return .system }
        if let preset = fan.presets.first(where: { $0.name == active.label && $0.targets == active.targets }) {
            return .preset(preset.id)
        }
        return .custom
    }

    /// 고른 값의 (목표, 이름, 직접 정하기인지). 시스템 제어면 nil이에요.
    private var selectedValues: (targets: [FanTarget], label: String, isCustom: Bool)? {
        switch selectedChoice {
        case .system:
            return nil
        case .preset(let id):
            guard let preset = fan.presets.first(where: { $0.id == id }) else { return nil }
            return (preset.targets, preset.name, false)
        case .custom:
            return (customDrafts.map(\.target), "직접 정하기", true)
        }
    }

    private var canApply: Bool {
        guard !fan.isSending else { return false }
        if selectedChoice == .system {
            return fan.active != nil
        }
        guard holdSelection.hold != nil, let values = selectedValues else { return false }
        return fan.isValid(values.targets)
    }

    private var applyTitle: String {
        if selectedChoice == .system {
            return "시스템 제어 적용"
        }
        let hold = holdSelection.hold?.text ?? FanHoldSelection.label(.custom)
        return (fan.active == nil ? "적용 · " : "바꿔서 적용 · ") + hold
    }

    private func apply() {
        guard canApply else { return }
        if selectedChoice == .system {
            fan.returnToSystem()
            return
        }
        guard let values = selectedValues, let hold = holdSelection.hold else { return }
        fan.apply(targets: values.targets, label: values.label, hold: hold, isCustom: values.isCustom)
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        // 직접 정하기로 고정 중이면 그 값, 아니면 마지막에 쓴 값에서 시작해요.
        if let active = fan.active, currentChoice == .custom {
            customDrafts = FanDraft.drafts(active.targets, limits: fan.limits)
        } else {
            customDrafts = FanDraft.drafts(fan.initialCustom, limits: fan.limits)
        }
        holdSelection = FanHoldSelection(fan.defaultHold)
        fan.refresh()
    }
}

/// 팬 제어 상태 상자: 시스템 제어 · 고정 · 시스템 제어 복귀 · 보조 프로그램 허용 필요
private struct FanStatusBox: View {
    @Environment(FanControlModel.self) private var fan
    let allowHelper: () -> Void

    private struct Info {
        var title: String
        var details: [String] = []
        var tone: Tone = .neutral
        var showsBack = false
        var showsAllow = false
        /// 시간 한정 고정이면 시스템 제어로 돌아갈 시각 (남은 시간을 분:초로 세어 보여줘요)
        var countdownEnd: Date?
    }

    private enum Tone {
        case neutral, active, warning
    }

    var body: some View {
        let info = self.info()
        // 켜짐·꺼짐 점은 두지 않아요. 시스템 제어가 '꺼진' 것처럼 보이기 때문이에요. (2026-10-30 사용자 요청)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                ForEach(info.details, id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(info.tone == .warning ? StatusColor.warningText : Color.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let end = info.countdownEnd {
                    CountdownLine(end: end)
                }
            }
            Spacer(minLength: 8)
            if info.showsBack {
                Button("시스템 제어로") {
                    fan.returnToSystem()
                }
                .controlSize(.small)
                .disabled(fan.isSending)
            }
            if info.showsAllow {
                Button("허용하기", action: allowHelper)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(info.tone), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func info() -> Info {
        switch fan.helperStatus {
        case .notRegistered, .requiresApproval:
            return Info(title: "팬 제어: 보조 프로그램 허용 필요", tone: .warning, showsAllow: true)
        case .failed:
            return Info(title: "팬 제어: 보조 프로그램 연결 실패", tone: .warning)
        case .unknown:
            return Info(title: "상태 확인")
        case .enabled:
            break
        }
        guard let state = fan.state else {
            return Info(title: "상태 확인")
        }
        if let active = state.active {
            if let expiresAt = active.expiresAt {
                return Info(title: "고정 · \(active.label)", details: [FanText.targets(active.targets)],
                            tone: .active, showsBack: true, countdownEnd: expiresAt)
            }
            return Info(title: "고정 · \(active.label)",
                        details: [FanText.targets(active.targets), "계속 유지 · 앱 종료 시 시스템 제어 복귀"],
                        tone: .active, showsBack: true)
        }
        if let event = state.lastReturn {
            return Info(title: "시스템 제어 복귀",
                        details: ["\(ValueFormat.clockMinutes(event.at)) · \(event.reason.text)"],
                        tone: .warning)
        }
        return Info(title: "시스템 제어")
    }

    private func background(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: Color.primary.opacity(0.035)
        case .active: Color.accentColor.opacity(0.10)
        case .warning: StatusColor.warningBackground
        }
    }
}

/// '4:59 남음 · 17:25 시스템 제어 복귀'. 남은 시간은 macOS가 1초마다 세어 줘요.
private struct CountdownLine: View {
    let end: Date

    var body: some View {
        // 이미 지난 시각이면 0:00으로 보여요. (범위가 거꾸로면 앱이 멈춰서 미리 맞춰요)
        let now = Date()
        let range = now...max(end, now)
        Text("\(Text(timerInterval: range, countsDown: true)) 남음 · \(ValueFormat.clockMinutes(end)) 시스템 제어 복귀")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

/// 온도·팬 카드 제목 옆 '자동'·'고정' 표시
struct FanModeBadge: View {
    @Environment(FanControlModel.self) private var fan

    var body: some View {
        if fan.isAvailable, !fan.limits.isEmpty {
            let fixed = fan.active != nil
            Text(fixed ? "고정" : "자동")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(fixed ? Color.white : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(fixed ? Color.accentColor : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()
        }
    }
}
