import AppKit
import SwiftUI

/// 설정에서 고를 수 있는 여덟 가지 색이에요. (빨강·주황·노랑·초록·청록·파랑·남색·보라)
/// 청록은 디스크 항목을 더하면서 넣었어요. (2026-11-03 사용자 결정)
nonisolated enum ItemColor: String, CaseIterable, Identifiable, Hashable, Sendable {
    case red, orange, yellow, green, teal, blue, indigo, purple

    var id: Self { self }

    var name: String {
        switch self {
        case .red: "빨강"
        case .orange: "주황"
        case .yellow: "노랑"
        case .green: "초록"
        case .teal: "청록"
        case .blue: "파랑"
        case .indigo: "남색"
        case .purple: "보라"
        }
    }

    /// 막대와 선에 쓰는 색이에요. 밝은 화면과 어두운 화면에서 각각 잘 보이는 값을 써요.
    var color: Color {
        .dynamic(light: lightHex, dark: darkHex)
    }

    /// 같은 항목의 두 번째 계열(E 코어, 업로드, 왼쪽 팬)에 쓰는 연한 색이에요.
    var secondaryColor: Color {
        color.opacity(0.5)
    }

    /// 밝은 배경에서도 선이 보이도록 진하게 잡은 값이에요. (노랑은 특히 진하게)
    private var lightHex: UInt32 {
        switch self {
        case .red: 0xD93025
        case .orange: 0xC96A00
        case .yellow: 0xAD8600
        case .green: 0x2E9E4F
        case .teal: 0x0B8793
        case .blue: 0x1F5FD0
        case .indigo: 0x4338CA
        case .purple: 0x9B3CC8
        }
    }

    /// 어두운 배경에서 잘 보이도록 밝게 잡은 값이에요.
    private var darkHex: UInt32 {
        switch self {
        case .red: 0xFF6B5E
        case .orange: 0xFF9F0A
        case .yellow: 0xFFD60A
        case .green: 0x32D74B
        case .teal: 0x40CDD6
        case .blue: 0x4D8DFF
        case .indigo: 0x7D7AFF
        case .purple: 0xBF5AF2
        }
    }
}

extension Color {
    /// 밝은 화면과 어두운 화면에서 다른 값을 쓰는 색을 만들어요. (0xRRGGBB)
    nonisolated static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return Color.makeNSColor(isDark ? dark : light)
        }
        return Color(nsColor: nsColor)
    }

    nonisolated private static func makeNSColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
