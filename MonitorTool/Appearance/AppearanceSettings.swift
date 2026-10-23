import Foundation
import Observation

/// 항목별 색 설정이에요. 고른 색은 앱을 다시 켜도 남아요. (UserDefaults)
@Observable
final class AppearanceSettings {
    private(set) var colors: [MonitorItem: ItemColor] = [:]

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
    }

    func color(for item: MonitorItem) -> ItemColor {
        colors[item] ?? item.defaultColor
    }

    func setColor(_ color: ItemColor, for item: MonitorItem) {
        colors[item] = color
        defaults.set(color.rawValue, forKey: Self.key(for: item))
    }

    func resetToDefaults() {
        for item in MonitorItem.allCases {
            colors[item] = item.defaultColor
            defaults.removeObject(forKey: Self.key(for: item))
        }
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
