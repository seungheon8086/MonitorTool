import Foundation
import Observation

/// 항목별 색 설정이에요. 고른 색은 앱을 다시 켜도 남아요. (UserDefaults)
@Observable
final class AppearanceSettings {
    private(set) var colors: [MonitorItem: ItemColor] = [:]
    /// 색을 바꿀 때마다 불러요. (위젯도 같은 색을 쓰도록 공유 파일을 다시 써요)
    @ObservationIgnored var onChange: (() -> Void)?

    /// 패널 유리 종류: macOS Liquid Glass의 '투명'(clear)과 '기본'(regular) (2026-11-03 사용자 요청)
    private(set) var panelGlass: PanelGlass = .regular
    /// 패널 유리에 입히는 색조: −1 = 가장 어둡게(검정), 0 = 입히지 않음, 1 = 가장 밝게(흰색). Liquid Glass의 색조(tint)로 넣어요.
    private(set) var panelTint: Double = 0
    /// 패널 뒤 배경 흐림: 0 = 유리 자체 흐림만, 1 = 가장 흐리게
    private(set) var panelBlur: Double = 0
    /// 패널 배경을 바꿀 때마다 불러요. (패널 창이 바로 반영해요)
    @ObservationIgnored var onPanelBackgroundChange: (() -> Void)?

    var panelBackgroundIsDefault: Bool {
        panelGlass == .regular && panelTint == 0 && panelBlur == 0
    }

    /// 고른 색을 저장하는 곳 (let이라 화면 갱신 추적 대상이 아니에요)
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [MonitorItem: ItemColor] = [:]
        for item in MonitorItem.allCases {
            let saved = defaults.string(forKey: Self.key(for: item)).flatMap(ItemColor.init(rawValue:))
            loaded[item] = saved ?? item.defaultColor
        }
        colors = loaded
        if let saved = defaults.string(forKey: Self.panelGlassKey).flatMap(PanelGlass.init(rawValue:)) {
            panelGlass = saved
        }
        if let saved = defaults.object(forKey: Self.panelTintKey) as? Double, saved.isFinite {
            panelTint = Self.clampedTint(saved)
        }
        if let saved = defaults.object(forKey: Self.panelBlurKey) as? Double, saved.isFinite {
            panelBlur = min(max(saved, 0), 1)
        }
        // 처음 만든 투명도 슬라이더(알파값 방식, 커밋 전에 바꿈)의 값은 지워요.
        defaults.removeObject(forKey: "panelBackground")
    }

    func setPanelGlass(_ glass: PanelGlass) {
        panelGlass = glass
        defaults.set(glass.rawValue, forKey: Self.panelGlassKey)
        onPanelBackgroundChange?()
    }

    func setPanelTint(_ value: Double) {
        guard value.isFinite else { return }
        panelTint = Self.clampedTint(value)
        defaults.set(panelTint, forKey: Self.panelTintKey)
        onPanelBackgroundChange?()
    }

    func setPanelBlur(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0), 1)
        panelBlur = clamped < 0.02 ? 0 : clamped
        defaults.set(panelBlur, forKey: Self.panelBlurKey)
        onPanelBackgroundChange?()
    }

    func resetPanelBackground() {
        panelGlass = .regular
        panelTint = 0
        panelBlur = 0
        defaults.removeObject(forKey: Self.panelGlassKey)
        defaults.removeObject(forKey: Self.panelTintKey)
        defaults.removeObject(forKey: Self.panelBlurKey)
        onPanelBackgroundChange?()
    }

    /// −1…1로 자르고, 가운데 근처는 0(색조 없음)에 붙여요. (슬라이더로 정확히 0을 맞추기 어려워서)
    private static func clampedTint(_ value: Double) -> Double {
        let clamped = min(max(value, -1), 1)
        return abs(clamped) < 0.04 ? 0 : clamped
    }

    private static let panelGlassKey = "panelGlass"
    private static let panelTintKey = "panelTint"
    private static let panelBlurKey = "panelBlur"

    func color(for item: MonitorItem) -> ItemColor {
        colors[item] ?? item.defaultColor
    }

    func setColor(_ color: ItemColor, for item: MonitorItem) {
        colors[item] = color
        defaults.set(color.rawValue, forKey: Self.key(for: item))
        onChange?()
    }

    func resetToDefaults() {
        for item in MonitorItem.allCases {
            colors[item] = item.defaultColor
            defaults.removeObject(forKey: Self.key(for: item))
        }
        onChange?()
    }

    /// CPU·GPU·ANE 중 같은 색을 고른 항목이 있는지예요. 메모리 트래픽 그래프에 셋이 함께 나와서 구분이 어려워져요.
    var processorColorsClash: Bool {
        let picked = [color(for: .cpu), color(for: .gpu), color(for: .ane)]
        return Set(picked).count < picked.count
    }

    private static func key(for item: MonitorItem) -> String {
        "itemColor.\(item.rawValue)"
    }
}

/// 패널 유리 종류 (NSGlassEffectView.Style과 같은 두 가지)
enum PanelGlass: String, CaseIterable, Identifiable {
    /// 뒤가 더 많이 비치는 유리
    case clear
    /// macOS 기본 유리
    case regular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: "투명"
        case .regular: "기본"
        }
    }
}

