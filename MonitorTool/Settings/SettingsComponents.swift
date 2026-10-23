import AppKit
import SwiftUI

// 설정 창의 탭들이 함께 쓰는 작은 조각이에요. (화면 시안 '설정 창')

/// 설정 창의 공통 크기
enum SettingsLayout {
    /// 탭 내용의 폭 (시안과 같아요)
    static let width: CGFloat = 520
}

/// 설정 창의 소제목 (예: '패널 단축키')
struct SettingsSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
    }
}

/// 소제목 아래 설명 글
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 둥근 상자 (밝은 화면에서는 흰 바탕, 어두운 화면에서는 어두운 바탕)
struct SettingsBox<Content: View>: View {
    var spacing: CGFloat = 8
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
