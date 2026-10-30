import AppKit
import SwiftUI

// 설정 창 '팬' 탭과 패널 '팬 제어'가 함께 쓰는 입력 조각이에요. (화면 시안 '팬 제어')

/// 팬 값 문구 (개조식)
enum FanText {
    /// '정지', '2,000'
    static func value(_ target: FanTarget) -> String {
        switch target {
        case .stopped: "정지"
        case .rpm(let value): value.formatted()
        }
    }

    /// '왼쪽 2,000 · 오른쪽 2,300'
    static func targets(_ targets: [FanTarget]) -> String {
        targets.enumerated()
            .map { "\(FanName.short(id: $0.offset, count: targets.count)) \(value($0.element))" }
            .joined(separator: " · ")
    }
}

/// 편집 중인 팬 하나의 값. 정지를 껐을 때 돌아갈 RPM을 기억해요.
struct FanDraft: Hashable {
    var stopped: Bool
    var rpm: Int

    init(_ target: FanTarget, limit: FanLimit) {
        switch target {
        case .stopped:
            stopped = true
            rpm = min(max(2000, limit.minimum), limit.maximum)
        case .rpm(let value):
            stopped = false
            rpm = value
        }
    }

    var target: FanTarget {
        stopped ? .stopped : .rpm(rpm)
    }

    static func drafts(_ targets: [FanTarget], limits: [FanLimit]) -> [FanDraft] {
        zip(targets, limits).map { FanDraft($0, limit: $1) }
    }
}

/// 팬 하나: 이름 · 정지 · − RPM + · 범위 안내
struct FanDraftEditor: View {
    let limit: FanLimit
    let count: Int
    @Binding var draft: FanDraft

    private var name: String {
        FanName.short(id: limit.id, count: count)
    }

    private var isValid: Bool {
        limit.accepts(draft.target)
    }

    private var rangeText: String {
        "\(limit.minimum.formatted())–\(limit.maximum.formatted())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 48, alignment: .leading)
                Toggle("정지", isOn: $draft.stopped)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    stepButton(symbol: "minus", delta: -100, label: "\(name) 100 RPM 내리기")
                    TextField("", value: $draft.rpm, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 48)
                        .accessibilityLabel(Text("\(name) 목표 RPM"))
                    Text("RPM")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 3)
                    stepButton(symbol: "plus", delta: 100, label: "\(name) 100 RPM 올리기")
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                }
                .disabled(draft.stopped)
                .opacity(draft.stopped ? 0.45 : 1)
            }
            if !draft.stopped {
                Text(isValid ? "범위 \(rangeText)" : "범위 초과 · \(rangeText)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(isValid ? Color.secondary : StatusColor.error)
                    .padding(.leading, 56)
            }
        }
    }

    private func stepButton(symbol: String, delta: Int, label: String) -> some View {
        Button {
            let stepped = Int((Double(draft.rpm + delta) / 100).rounded()) * 100
            draft.rpm = min(max(stepped, limit.minimum), limit.maximum)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// 복귀 시간 고르기 (5분 · 15분 · 30분 · 60분 · 직접 · 계속 유지)
struct FanHoldSelection: Hashable {
    enum Choice: Hashable {
        case minutes(Int)
        case custom
        case keep
    }

    var choice: Choice
    /// '직접'일 때의 분
    var customMinutes: Int

    static let choices: [Choice] = FanHold.presetMinutes.map { Choice.minutes($0) } + [.custom, .keep]

    init(_ hold: FanHold) {
        switch hold {
        case .keep:
            choice = .keep
            customMinutes = 45
        case .minutes(let value) where FanHold.presetMinutes.contains(value):
            choice = .minutes(value)
            customMinutes = 45
        case .minutes(let value):
            choice = .custom
            customMinutes = value
        }
    }

    /// 고른 값. '직접'에 1분보다 작은 값이면 nil이에요.
    var hold: FanHold? {
        switch choice {
        case .minutes(let value): .minutes(value)
        case .keep: .keep
        case .custom: customMinutes >= 1 ? .minutes(customMinutes) : nil
        }
    }

    static func label(_ choice: Choice) -> String {
        switch choice {
        case .minutes(let value): "\(value)분"
        case .custom: "직접"
        case .keep: "계속 유지"
        }
    }
}

struct FanHoldPicker: View {
    @Binding var selection: FanHoldSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(FanHoldSelection.choices, id: \.self) { choice in
                    let isSelected = selection.choice == choice
                    Button {
                        selection.choice = choice
                    } label: {
                        Text(FanHoldSelection.label(choice))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(isSelected ? 0.14 : 0), radius: 1, y: 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if selection.choice == .custom {
                HStack(spacing: 6) {
                    TextField("", value: $selection.customMinutes, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 60)
                        .accessibilityLabel(Text("복귀까지 분"))
                    Text("분 후 복귀")
                        .font(.system(size: 12))
                }
            }
        }
    }
}
