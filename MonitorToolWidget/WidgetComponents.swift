import Foundation
import SwiftUI
import WidgetKit

// 패널(Panel/Components)과 같은 모양의 작은 화면 조각이에요. 위젯 확장은 패널 코드를 함께 컴파일하지 않아서 따로 둬요.

/// 상태를 알리는 색이에요. 패널의 StatusColor와 같은 값이에요.
enum WidgetStatusColor {
    static let warningText = Color.dynamic(light: 0x8A4F00, dark: 0xFFB340)
    static let warningBackground = Color.dynamic(light: 0xFFF1D6, dark: 0x4A3511)
    static let error = Color.dynamic(light: 0xB42318, dark: 0xFF6B5E)
    static let active = Color.green
}

/// 패널 카드와 같은 바탕 (primary 4.5%).
/// 모서리는 위젯 바깥 모서리와 같은 중심을 갖도록 ContainerRelativeShape로 그려요.
/// (바깥 반지름에서 위젯 가장자리까지의 간격을 뺀 반지름이 돼요)
struct WidgetCard<Content: View>: View {
    var padding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.045), in: ContainerRelativeShape())
    }
}

/// 카드 제목 (패널과 같은 13 semibold보다 한 단계 작게)
struct WidgetCardTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
    }
}

/// 사용률 막대. 값이 없으면 빈 막대만 보여요.
struct WidgetUsageBar: View {
    let fraction: Double?
    let color: Color
    var height: CGFloat = 4

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
    }
}

/// 값이 정상이면 숫자, 오래된 값이면 시계와 흐린 숫자, 아니면 상태 글자예요. (패널 ValueText와 같은 규칙)
struct WidgetValueText<Value: Hashable & Sendable & Codable>: View {
    let reading: Reading<Value>
    let format: (Value) -> String
    var font: Font = .system(size: 13, weight: .semibold)

    var body: some View {
        if let value = reading.okValue {
            Text(format(value))
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
        } else if case .stale = reading.state, let value = reading.value {
            HStack(spacing: 2) {
                Image(systemName: "clock")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(WidgetStatusColor.warningText)
                Text(format(value))
                    .font(font)
                    .monospacedDigit()
                    .lineLimit(1)
                    .opacity(0.45)
            }
        } else {
            WidgetStateText(state: reading.state)
        }
    }
}

/// 숫자 대신 보여주는 상태 글자예요. 읽지 못한 값을 0으로 보여주지 않아요.
struct WidgetStateText: View {
    let state: ValueState

    var body: some View {
        switch state {
        case .ok, .stale:
            EmptyView()
        case .preparing:
            label("준비 중")
        case .unsupported:
            label("지원 안 함")
        case .notMeasurable:
            label("측정 불가")
        case .off:
            label("꺼짐")
        case .permissionNeeded:
            Text("권한 필요")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WidgetStatusColor.warningText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(WidgetStatusColor.warningBackground,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()
        case .failed:
            Label("읽지 못함", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(WidgetStatusColor.error)
                .lineLimit(1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// 작은 이름표와 값을 한 줄로: '전력 ⋯ 2.3 W'
struct WidgetValueRow<Value: Hashable & Sendable & Codable>: View {
    let label: String
    let reading: Reading<Value>
    let format: (Value) -> String
    var font: Font = .system(size: 12, weight: .semibold)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            WidgetValueText(reading: reading, format: format, font: font)
        }
    }
}

/// 맨 아래 '전력' 줄처럼 위에 가는 선을 두른 줄
struct WidgetTopRule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.top, 4)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
            }
    }
}

/// ANE '사용 중 / 쉬는 중'
struct WidgetANEActivity: View {
    let reading: Reading<Bool>

    var body: some View {
        if let isActive = reading.okValue {
            HStack(spacing: 4) {
                if isActive {
                    Circle()
                        .fill(WidgetStatusColor.active)
                        .frame(width: 6, height: 6)
                    Text("사용 중")
                } else {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1.2)
                        .frame(width: 6, height: 6)
                    Text("쉬는 중")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
        } else {
            WidgetStateText(state: reading.state)
        }
    }
}

/// 메모리 압력 (점 + 글)
struct WidgetPressureLabel: View {
    let reading: Reading<MemoryPressure>

    var body: some View {
        if let pressure = reading.okValue {
            HStack(spacing: 3) {
                Circle()
                    .fill(color(for: pressure))
                    .frame(width: 6, height: 6)
                Text(title(for: pressure))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } else {
            WidgetStateText(state: reading.state)
        }
    }

    private func title(for pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "압력 정상"
        case .warning: "압력 주의"
        case .critical: "압력 높음"
        }
    }

    private func color(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: WidgetStatusColor.active
        case .warning: Color.yellow
        case .critical: WidgetStatusColor.error
        }
    }
}

/// 그래프에 그릴 선 하나
struct WidgetLine: Identifiable {
    let label: String
    let values: [Double?]
    let color: Color
    var dashed = false

    var id: String { label }
}

/// 칸 값으로 그린 꺾은선 그래프예요. 값이 없는 칸에서는 선을 끊어요(0으로 잇지 않아요).
/// 왼쪽에 위·가운데·아래 눈금 숫자를 적어 지금 값이 어느 정도인지 바로 보이게 해요.
struct WidgetSparkline: View {
    let lines: [WidgetLine]
    /// 세로 축 맨 위 값. nil이면 값에 맞춰 보기 좋은 수(1·2·2.5·5 × 10ⁿ)로 올려요.
    var fixedMaximum: Double?
    /// 값이 작아도 이 높이까지는 축을 잡아요. (조금만 흔들려도 꽉 차 보이지 않게)
    var minimumMaximum: Double = 1
    /// 0을 가운데 두고 위아래를 같은 폭으로 (배터리 순전력처럼 부호가 있는 값)
    var symmetric = false
    /// 맨 위 값을 고를 때 값에 곱하는 수예요. 곱한 단위에서 보기 좋은 수를 고르고 다시 나눠요.
    /// (네트워크를 비트로 보면 8: 바이트에서 고른 2.5 MB는 20 Mb라, 비트에서 고르면 눈금이 깔끔해요)
    var scaleFactor: Double = 1
    /// 왼쪽 눈금 글자. nil이면 눈금을 그리지 않아요.
    var axisFormat: ((Double) -> String)?

    var body: some View {
        let top = scaleTop
        let bottom = symmetric ? -top : 0
        HStack(spacing: 3) {
            if let axisFormat {
                GeometryReader { proxy in
                    let height = proxy.size.height
                    ZStack(alignment: .trailing) {
                        axisLabel(axisFormat(top), y: 4, width: proxy.size.width)
                        axisLabel(axisFormat((top + bottom) / 2), y: height / 2, width: proxy.size.width)
                        axisLabel(axisFormat(bottom), y: height - 4, width: proxy.size.width)
                    }
                }
                .frame(width: 26)
            }
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    // 위·가운데·아래 기준선 (부호가 있는 값이면 가운데가 0)
                    Path { path in
                        for y in [0, size.height / 2, size.height] {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    ForEach(lines) { line in
                        path(for: line.values, in: size, top: top, bottom: bottom)
                            .stroke(line.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round,
                                                                   dash: line.dashed ? [3, 2] : []))
                    }
                }
            }
        }
    }

    private func axisLabel(_ text: String, y: CGFloat, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 8))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: width, alignment: .trailing)
            .position(x: width / 2, y: y)
    }

    private var scaleTop: Double {
        if let fixedMaximum { return fixedMaximum }
        let largest = lines.flatMap(\.values).compactMap { $0 }.filter(\.isFinite).map(abs).max() ?? 0
        let factor = scaleFactor.isFinite && scaleFactor > 0 ? scaleFactor : 1
        return WidgetSparkline.niceCeiling(max(largest * 1.1, minimumMaximum) * factor) / factor
    }

    /// 1·2·2.5·5 × 10ⁿ 중 x 이상인 가장 작은 수 (눈금 글자가 깔끔하게)
    static func niceCeiling(_ x: Double) -> Double {
        guard x.isFinite, x > 0 else { return 1 }
        let base = pow(10, floor(log10(x)))
        let fraction = x / base
        let nice: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10
        return nice * base
    }

    private func path(for values: [Double?], in size: CGSize, top: Double, bottom: Double) -> Path {
        Path { path in
            guard values.count > 1, top > bottom else { return }
            let step = size.width / CGFloat(values.count - 1)
            var drawing = false
            for (index, value) in values.enumerated() {
                guard let value, value.isFinite else {
                    drawing = false
                    continue
                }
                let ratio = min(max((value - bottom) / (top - bottom), 0), 1)
                let point = CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(ratio)))
                if drawing {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    // 앞뒤가 비어 있는 칸 하나도 보이게 점처럼 아주 짧게 그어요.
                    path.addLine(to: CGPoint(x: point.x + 0.5, y: point.y))
                    drawing = true
                }
            }
        }
    }
}

/// 범례 한 칸: 색 막대 + 이름 + 지금 값
struct WidgetLegendItem: View {
    let color: Color
    var dashed = false
    let label: String
    let value: String?

    var body: some View {
        HStack(spacing: 3) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 2))
                path.addLine(to: CGPoint(x: 10, y: 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 2] : []))
            .frame(width: 10, height: 4)
            Text(label)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }
}
