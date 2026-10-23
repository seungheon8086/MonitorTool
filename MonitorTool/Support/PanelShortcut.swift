import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

/// 패널을 여닫는 전역 단축키예요. 설정 창 '일반'에서 바꿀 수 있고, 바꾼 값은 앱을 다시 켜도 남아요.
@Observable
final class PanelShortcut {
    /// 지금 쓰는 단축키
    private(set) var combo: HotKeyCombo
    /// 새 단축키를 기다리는 중인지 (설정 창의 칸이 '새 단축키를 누르세요'로 바뀌어요)
    private(set) var isRecording = false
    /// 잘못 눌렀거나 등록하지 못했을 때 보여줄 글
    private(set) var problem: String?

    /// 단축키가 바뀌면 불러요. (메뉴 막대 메뉴의 단축키 표시를 바꿔요)
    @ObservationIgnored var onChange: ((HotKeyCombo) -> Void)?

    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var keyMonitor: Any?
    private let action: () -> Void
    private let defaults: UserDefaults
    private static let storageKey = "panelShortcut"

    /// - Parameter action: 단축키를 눌렀을 때 할 일 (패널 열기/닫기)
    /// 시스템 등록은 activate()에서 해요. 미리보기에서는 부르지 않아서 진짜 단축키를 건드리지 않아요.
    init(defaults: UserDefaults = .standard, action: @escaping () -> Void) {
        self.defaults = defaults
        self.action = action
        combo = PanelShortcut.load(from: defaults) ?? .standard
    }

    /// 지금 단축키를 시스템에 등록해요. 다른 앱이 쓰고 있어서 실패하면 false예요.
    @discardableResult
    func activate() -> Bool {
        hotKey?.unregister()
        hotKey = GlobalHotKey(keyCode: combo.keyCode, carbonModifiers: combo.carbonModifiers, action: action)
        guard hotKey != nil else {
            problem = "\(combo.displayText)는 다른 앱이 쓰고 있어서 등록하지 못했어요. 다른 조합으로 바꿔 주세요."
            return false
        }
        return true
    }

    /// 새 단축키 기다리기를 시작해요. 다음에 누르는 조합이 새 단축키가 되고, Esc를 누르면 취소돼요.
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        problem = nil
        // 지금 단축키를 그대로 다시 누를 수도 있게 잠깐 풀어 둬요.
        hotKey?.unregister()
        hotKey = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = RecordedKey(keyCode: event.keyCode,
                                  flags: event.modifierFlags,
                                  characters: event.charactersIgnoringModifiers ?? "",
                                  isRepeat: event.isARepeat)
            // 키 입력은 메인 스레드에서 들어와요. 그 사실을 컴파일러에게 알려 주고 처리해요.
            let handled = MainActor.assumeIsolated {
                self?.handle(key) ?? false
            }
            return handled ? nil : event
        }
    }

    /// 기다리기를 그만두고 원래 단축키로 돌아가요. (설정 창을 닫을 때도 불러요)
    func cancelRecording() {
        guard isRecording else { return }
        finishRecording(with: nil)
    }

    /// 기본 단축키(⌃⌥M)로 되돌려요.
    func resetToStandard() {
        if isRecording {
            stopKeyMonitor()
        }
        change(to: .standard)
    }

    // MARK: - 녹화

    private func handle(_ key: RecordedKey) -> Bool {
        guard !key.isRepeat else { return true }
        if key.keyCode == UInt16(kVK_Escape) {
            finishRecording(with: nil)
            return true
        }
        let newCombo = HotKeyCombo(keyCode: UInt32(key.keyCode),
                                   carbonModifiers: GlobalHotKey.carbonModifiers(from: key.flags),
                                   characters: key.characters)
        guard newCombo.hasRequiredModifier else {
            problem = "⌘·⌃·⌥ 중 하나 이상을 다른 키와 함께 눌러 주세요."
            return true
        }
        finishRecording(with: newCombo)
        return true
    }

    private func finishRecording(with newCombo: HotKeyCombo?) {
        stopKeyMonitor()
        if let newCombo {
            change(to: newCombo)
        } else {
            problem = nil
            activate()
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        isRecording = false
    }

    /// 새 조합을 등록해 보고, 되면 저장해요. 안 되면 원래 단축키를 그대로 둬요.
    private func change(to newCombo: HotKeyCombo) {
        hotKey?.unregister()
        hotKey = nil
        if let registered = GlobalHotKey(keyCode: newCombo.keyCode,
                                         carbonModifiers: newCombo.carbonModifiers,
                                         action: action) {
            hotKey = registered
            combo = newCombo
            problem = nil
            save()
            onChange?(newCombo)
        } else {
            activate()
            problem = "\(newCombo.displayText)는 다른 앱이 쓰고 있어서 바꾸지 못했어요. 다른 조합을 눌러 주세요."
        }
    }

    // MARK: - 저장

    private static func load(from defaults: UserDefaults) -> HotKeyCombo? {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(HotKeyCombo.self, from: data),
              saved.hasRequiredModifier else {
            return nil
        }
        return saved
    }

    private func save() {
        if let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// 녹화할 때 받은 키 입력이에요. 메인 액터로 넘기기 쉽게 값만 담아요.
nonisolated private struct RecordedKey: Sendable {
    var keyCode: UInt16
    var flags: NSEvent.ModifierFlags
    var characters: String
    var isRepeat: Bool
}
