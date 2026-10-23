import AppKit
import SwiftUI

// 패널 여러 곳에서 함께 쓰는 작은 화면 조각이에요.

/// 카드 배경이에요. 펼친 카드는 강조색으로 살짝 칠하고 테두리를 둘러요.
struct CardBackground: ViewModifier {
    var isExpanded: Bool

    func body(content: Content) -> some View {
        content
            .background(isExpanded ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isExpanded ? 0.30 : 0), lineWidth: 1)
            }
    }
}

/// 펼침 상태를 알려 주는 꺾쇠예요. 펼치면 위를 향해요.
struct ExpandChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
    }
}

/// 사용률 같은 비율을 보여주는 가로 막대예요. 값이 없으면 빈 막대만 보여요.
struct UsageBar: View {
    /// 0...1. nil이면 채우지 않아요.
    let fraction: Double?
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                if let fraction, fraction.isFinite {
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 값이 정상이면 숫자를, 아니면 상태(준비 중·권한 필요 등)를 보여줘요.
struct ValueText<Value: Hashable & Sendable & Codable>: View {
    let reading: Reading<Value>
    let format: (Value) -> String
    var font: Font = .system(size: 15, weight: .semibold)

    var body: some View {
        if let value = reading.okValue {
            Text(format(value))
                .font(font)
                .monospacedDigit()
        } else {
            StateText(state: reading.state)
        }
    }
}

/// 숫자 대신 보여주는 상태 글자예요. 읽지 못한 값을 0으로 보여주지 않아요.
struct StateText: View {
    let state: ValueState

    var body: some View {
        switch state {
        case .ok:
            EmptyView()
        case .preparing:
            Text("준비 중")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .unsupported:
            Text("지원 안 함")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .permissionNeeded:
            PermissionBadge()
        case .notMeasurable:
            Text("측정 불가")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .off:
            Text("꺼짐")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .failed:
            Label("읽지 못함", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(StatusColor.error)
        }
    }
}

/// '권한 필요' 표시예요.
struct PermissionBadge: View {
    var body: some View {
        Text("권한 필요")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StatusColor.warningText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(StatusColor.warningBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
    }
}

/// 상태를 알리는 색과 회색 표시예요. 항목 색 설정과 상관없이 늘 같아요.
enum StatusColor {
    static let warningText = Color.dynamic(light: 0x8A4F00, dark: 0xFFB340)
    static let warningBackground = Color.dynamic(light: 0xFFF1D6, dark: 0x4A3511)
    static let error = Color.dynamic(light: 0xB42318, dark: 0xFF6B5E)
    static let active = Color.green
    /// 메모리 트래픽의 나머지 기기 (화면·저장장치·그 밖)
    static let otherTraffic = Color.gray.opacity(0.6)
}

/// 작은 이름표 아래에 값을 보여줘요. (예: 'CPU 최고' / '61 °C')
struct LabeledValue<Value: Hashable & Sendable & Codable>: View {
    let label: String
    let reading: Reading<Value>
    let format: (Value) -> String
    var font: Font = .system(size: 15, weight: .semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ValueText(reading: reading, format: format, font: font)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 펼친 상세 정보를 담는 카드예요. 제목 오른쪽에는 그래프 기간 고르기 같은 작은 조작을 둬요.
/// 나타날 때는 카드 바로 아래에서 위→아래로 드러나며 펼쳐져요. (아래 RevealFromTop)
struct DetailCard<Accessory: View, Content: View>: View {
    let title: String
    /// 제목 오른쪽 (예: 1분·5분·30분 고르기)
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .transition(RevealFromTop())
    }
}

/// 카드를 펼치고 접을 때 쓰는 움직임이에요. 튀지 않고 부드럽게 멈춰요.
/// (2026-10-24 사용자 요청: 위에서 떨어지듯 나오지 않고, 메뉴가 펼쳐지듯 자연스럽게)
enum PanelMotion {
    static let expand: Animation = .smooth(duration: 0.32)
}

/// 상세가 카드 바로 아래에서 위→아래로 드러나며 펼쳐지는 전환이에요.
/// 상세는 제자리에 있고 보이는 높이만 늘어나요. 아래 카드가 밀려 내려가는 속도와 같아서 서로 겹치지 않아요.
/// 접을 때는 거꾸로 아래에서 위로 말려 들어가요.
struct RevealFromTop: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            // 위쪽 끝을 기준으로, 보이는 부분을 0에서 전체 높이까지 늘려요.
            .mask(alignment: .top) {
                Rectangle()
                    .scaleEffect(x: 1, y: phase.isIdentity ? 1 : 0.001, anchor: .top)
            }
    }
}

/// 값의 출처나 뜻을 알려 주는 작은 설명이에요.
struct SourceNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 둥근 상자 안의 안내 글이에요. (예: ANE 사용률을 보여주지 않는 이유)
struct InfoBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 색 점과 짧은 값을 붙인 표시예요. (예: ■ CPU 3.6)
struct ColorChip: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12))
                .monospacedDigit()
        }
    }
}

/// 상세 카드 안의 한 줄 목록 (이름 · 값)
struct ListRow<Trailing: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12))
            if let note {
                Text("· \(note)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
