import Foundation
import SwiftUI

/// 설정 창 '모양' 탭: 항목 색 고르기 (화면 시안 '설정 창 · 모양', 2026-10-23 사용자 요청)
struct AppearanceSettingsView: View {
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(title: "항목 색")
            SettingsNote(text: "패널과 위젯의 막대·그래프에 쓰는 색이에요. 항목마다 일곱 가지 중에서 골라요.")
            SettingsBox(spacing: 0, padding: 0) {
                ForEach(MonitorItem.allCases) { item in
                    if item != MonitorItem.allCases.first {
                        Divider()
                    }
                    ItemColorRow(item: item)
                }
            }
            if appearance.processorColorsClash {
                ClashWarning()
            }

            SettingsSectionTitle(title: "미리보기")
                .padding(.top, 12)
            SettingsBox(spacing: 0, padding: 6) {
                ForEach(Array(MonitorItem.allCases.enumerated()), id: \.element) { index, item in
                    ColorPreviewRow(item: item, seed: index)
                }
            }

            HStack(alignment: .center, spacing: 16) {
                Text("상태를 알리는 색(사용 중, 권한 필요, 오류)은 바뀌지 않아요. 위젯도 여기서 고른 색을 써요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("기본 색으로 되돌리기") {
                    appearance.resetToDefaults()
                }
            }
            .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
        .frame(width: SettingsLayout.width, alignment: .leading)
    }
}

/// 항목 하나의 색 고르기 줄 (이름 · 색 점 · 드롭다운)
private struct ItemColorRow: View {
    let item: MonitorItem
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                if let note = item.secondaryNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Circle()
                .fill(appearance.color(for: item).color)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Picker("\(item.title) 색", selection: selection) {
                ForEach(ItemColor.allCases) { color in
                    Text(color.name)
                        .tag(color)
                }
            }
            .labelsHidden()
            .frame(width: 96)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selection: Binding<ItemColor> {
        Binding(get: { appearance.color(for: item) },
                set: { appearance.setColor($0, for: item) })
    }
}

/// CPU·GPU·ANE에 같은 색을 골랐을 때의 안내
private struct ClashWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
            Text("CPU·GPU·ANE 중 같은 색을 고른 항목이 있어요. 메모리 트래픽 그래프에서는 세 항목이 함께 나와서 구분하기 어려워요.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(StatusColor.warningText)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StatusColor.warningBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 미리보기 한 줄: 고른 색으로 막대와 작은 선을 그려 봐요.
private struct ColorPreviewRow: View {
    let item: MonitorItem
    let seed: Int
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        let color = appearance.color(for: item)
        HStack(spacing: 12) {
            Text(item.title)
                .font(.system(size: 12))
                .frame(width: 64, alignment: .leading)
            UsageBar(fraction: Self.sampleFractions[seed % Self.sampleFractions.count], color: color.color)
                .frame(width: 96)
            ZStack {
                // 두 번째 계열이 있는 항목(CPU의 E 코어, 팬 2, 업로드)은 연한 선을 하나 더 그려요.
                if item.secondaryNote != nil {
                    Sparkline(values: Self.wave(seed: 53 + seed * 5, base: 0.3, amplitude: 0.3),
                              color: color.secondaryColor)
                }
                Sparkline(values: Self.wave(seed: 11 + seed * 7, base: 0.55, amplitude: 0.5),
                          color: color.color)
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .accessibilityHidden(true)
    }

    /// 시안과 같은 막대 길이 (CPU, GPU, ANE, 메모리, 온도·팬, 배터리, 네트워크 순서)
    private static let sampleFractions: [Double] = [0.34, 0.09, 0.40, 0.71, 0.61, 0.76, 0.45]

    /// 미리보기용 작은 곡선이에요. 시드가 같으면 늘 같은 모양이에요.
    private static func wave(seed: Int, base: Double, amplitude: Double) -> [Double] {
        var state = UInt64(seed)
        return (0..<28).map { (index: Int) -> Double in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(state >> 11) / 9_007_199_254_740_992 - 0.5
            let value = base + sin(Double(index) / 3) * amplitude * 0.5 + noise * amplitude
            return min(max(value, 0.08), 0.92)
        }
    }
}

/// 값들(0...1)을 차례로 이은 작은 선
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: proxy.size.width * Double(index) / Double(values.count - 1),
                                        y: proxy.size.height * (1 - value))
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

#if DEBUG
#Preview("모양") {
    AppearanceSettingsView()
        .environment(AppearanceSettings())
}
#endif
