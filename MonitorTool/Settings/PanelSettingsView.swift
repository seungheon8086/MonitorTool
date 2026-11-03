import Foundation
import SwiftUI

/// 설정 창 '패널' 탭: 패널 배경과 항목 순서 (2026-11-03 사용자 요청으로 '모양' 탭에서 나눔)
struct PanelSettingsView: View {
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(title: "패널 배경")
            SettingsBox(spacing: 0, padding: 0) {
                PanelBackgroundRow()
            }

            SettingsSectionTitle(title: "항목 순서")
                .padding(.top, 12)
            SettingsBox(spacing: 0, padding: 0) {
                PanelOrderBox()
            }

            HStack(alignment: .center, spacing: 16) {
                Spacer(minLength: 0)
                Button("기본 순서로") {
                    withAnimation(.smooth(duration: 0.25)) {
                        appearance.resetPanelOrder()
                    }
                }
                .disabled(appearance.panelOrderIsDefault)
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
                Text("글자")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Picker("글자", selection: text) {
                    ForEach(PanelTextColor.allCases) { color in
                        Text(color.title)
                            .tag(color)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
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

    private var text: Binding<PanelTextColor> {
        Binding(get: { appearance.panelText },
                set: { appearance.setPanelText($0) })
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

#if DEBUG
#Preview("패널") {
    PanelSettingsView()
        .environment(AppearanceSettings())
}
#endif
