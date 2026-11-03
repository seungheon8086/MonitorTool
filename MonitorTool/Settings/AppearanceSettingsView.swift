import Foundation
import SwiftUI

/// 설정 창 '모양' 탭: 항목 색 고르기 (화면 시안 '설정 창 · 모양', 2026-10-23 사용자 요청)
struct AppearanceSettingsView: View {
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(title: "패널 배경")
            SettingsBox(spacing: 0, padding: 0) {
                PanelBackgroundRow()
            }

            SettingsSectionTitle(title: "항목 색")
                .padding(.top, 12)

            SettingsBox(spacing: 0, padding: 0) {
                ForEach(MonitorItem.allCases) { item in
                    if item != MonitorItem.allCases.first {
                        Divider()
                    }
                    ItemColorRow(item: item)
                }
            }

            SettingsSectionTitle(title: "미리보기")
                .padding(.top, 12)
            SettingsBox(spacing: 0, padding: 6) {
                ForEach(Array(MonitorItem.allCases.enumerated()), id: \.element) { index, item in
                    ColorPreviewRow(item: item, seed: index)
                }
            }

            HStack(alignment: .center, spacing: 16) {
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

/// 패널 배경: macOS Liquid Glass의 유리 종류(투명·기본)와 색조(가운데 없음, 왼쪽 어둡게, 오른쪽 밝게) (2026-11-03 사용자 요청)
private struct PanelBackgroundRow: View {
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("유리")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Picker("유리", selection: glass) {
                    ForEach(PanelGlass.allCases) { glass in
                        Text(glass.title)
                            .tag(glass)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            HStack(spacing: 10) {
                Text("색조")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Text("어둡게")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: tint, in: -1...1)
                    .frame(width: 180)
                    .accessibilityLabel(Text("패널 유리 색조"))
                Text("밝게")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            HStack(spacing: 10) {
                Text("배경 흐림")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Text("없음")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: blur, in: 0...1)
                    .frame(width: 180)
                    .disabled(!WindowBlur.isAvailable)
                    .accessibilityLabel(Text("패널 뒤 배경 흐림"))
                Text("강하게")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            HStack {
                Spacer(minLength: 0)
                Button("기본으로") {
                    appearance.resetPanelBackground()
                }
                .disabled(appearance.panelBackgroundIsDefault)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var glass: Binding<PanelGlass> {
        Binding(get: { appearance.panelGlass },
                set: { appearance.setPanelGlass($0) })
    }

    private var blur: Binding<Double> {
        Binding(get: { appearance.panelBlur },
                set: { appearance.setPanelBlur($0) })
    }

    private var tint: Binding<Double> {
        Binding(get: { appearance.panelTint },
                set: { appearance.setPanelTint($0) })
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
                // 두 번째 계열이 있는 항목(CPU의 E 코어, 왼쪽 팬, 업로드)은 연한 선을 하나 더 그려요.
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
