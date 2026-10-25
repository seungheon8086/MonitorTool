import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Observation

/// 패널 단축키의 종류예요.
nonisolated enum PanelShortcutKind: String, Codable, Sendable {
    /// fn + Space (손쉬운 사용 권한이 필요해요)
    case fnSpace
    /// 직접 정한 조합 (기본 ⌃⌥M, 권한이 필요 없어요)
    case custom
}

/// fn + Space의 지금 상태예요.
nonisolated enum FnShortcutState: Equatable, Sendable {
    /// 쓰지 않아요 (단축키를 껐거나 직접 정한 조합을 써요)
    case off
    /// 받고 있어요
    case active
    /// 손쉬운 사용 허용을 기다려요
    case needsPermission
    /// 허용돼 있다는데 키 입력을 받지 못했어요
    case failed
}

/// 메뉴 막대 메뉴의 '패널 열기/닫기' 옆에 보여줄 키예요. (메뉴는 보여주기만 해요)
struct MenuShortcut {
    var key: String
    var modifiers: NSEvent.ModifierFlags
}

/// 패널을 여닫는 전역 단축키예요. 설정 창 '일반'에서 켜고 끄고, fn + Space와 직접 정한 조합 중에서 골라요.
/// (2026-10-25 사용자 결정: 기본은 fn + Space, 원하면 직접 정한 조합. 스위치 하나로 전역 호출 전체를 꺼요)
/// 고른 값은 앱을 다시 켜도 남아요.
@Observable
final class PanelShortcut {
    /// 어디서든 단축키로 패널을 여는 기능이 켜져 있는지
    private(set) var isEnabled: Bool
    /// 쓰는 단축키 종류
    private(set) var kind: PanelShortcutKind
    /// 직접 정한 조합 (기본 ⌃⌥M)
    private(set) var combo: HotKeyCombo
    /// fn + Space의 상태
    private(set) var fnState: FnShortcutState = .off
    /// 새 조합을 기다리는 중인지 (설정 창의 칸이 '새 단축키를 누르세요'로 바뀌어요)
    private(set) var isRecording = false
    /// 잘못 눌렀거나 등록하지 못했을 때 보여줄 글
    private(set) var problem: String?

    /// 단축키가 바뀌거나 동작 여부가 바뀌면 불러요. (메뉴 막대 메뉴의 단축키 표시를 바꿔요)
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var keyMonitor: Any?
    /// fn + Space를 받는 동안에는 허용이 꺼졌는지, 허용을 기다리는 동안에는 허용됐는지 살피는 타이머
    @ObservationIgnored private var checkTimer: Timer?
    @ObservationIgnored private var checkInterval: TimeInterval?
    /// 이때까지는 허용을 기다리며 자주 살펴요. (허용 창을 띄운 뒤 10분)
    @ObservationIgnored private var permissionWaitUntil: Date?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    private let action: () -> Void
    private let defaults: UserDefaults
    private static let comboKey = "panelShortcut"
    private static let enabledKey = "panelShortcutEnabled"
    private static let kindKey = "panelShortcutKind"

    /// 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용
    private static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    /// - Parameter action: 단축키를 눌렀을 때 할 일 (패널 열기/닫기)
    /// 시스템 등록은 activate()에서 해요. 미리보기에서는 부르지 않아서 진짜 단축키를 건드리지 않아요.
    init(defaults: UserDefaults = .standard, action: @escaping () -> Void) {
        self.defaults = defaults
        self.action = action
        combo = PanelShortcut.loadCombo(from: defaults) ?? .standard
        isEnabled = defaults.object(forKey: PanelShortcut.enabledKey) as? Bool ?? true
        kind = defaults.string(forKey: PanelShortcut.kindKey).flatMap(PanelShortcutKind.init(rawValue:)) ?? .fnSpace
    }

    // MARK: - 보여주기

    /// 패널 머리글에 보여줄 단축키 (꺼져 있으면 nil)
    var displayText: String? {
        guard isEnabled else { return nil }
        switch kind {
        case .fnSpace:
            return "fn Space"
        case .custom:
            return combo.displayText
        }
    }

    /// 켜져 있는데 지금 동작하지 않아서 알려야 하는지 (권한이 없거나 등록하지 못했을 때)
    var needsAttention: Bool {
        guard isEnabled, !isRecording else { return false }
        switch kind {
        case .fnSpace:
            return fnState == .needsPermission || fnState == .failed
        case .custom:
            return problem != nil
        }
    }

    /// 메뉴 막대 메뉴에 보여줄 키 (꺼져 있으면 빈 글자)
    var menuShortcut: MenuShortcut {
        guard isEnabled else { return MenuShortcut(key: "", modifiers: []) }
        switch kind {
        case .fnSpace:
            return MenuShortcut(key: " ", modifiers: [.function])
        case .custom:
            return MenuShortcut(key: combo.menuKeyEquivalent,
                                modifiers: GlobalHotKey.modifierFlags(fromCarbon: combo.carbonModifiers))
        }
    }

    // MARK: - 켜기·고르기

    /// 지금 설정대로 단축키를 등록해요. 직접 정한 조합을 다른 앱이 쓰고 있어서 등록하지 못하면 false예요.
    /// - Parameter promptForPermission: fn + Space인데 손쉬운 사용 권한이 없으면 macOS의 허용 창을 띄워요.
    @discardableResult
    func activate(promptForPermission: Bool = false) -> Bool {
        installObserversIfNeeded()
        hotKey?.unregister()
        hotKey = nil
        FnSpaceHotKey.stop()
        defer { updateCheckTimer() }

        guard isEnabled else {
            fnState = .off
            problem = nil
            return true
        }
        switch kind {
        case .custom:
            fnState = .off
            hotKey = GlobalHotKey(keyCode: combo.keyCode, carbonModifiers: combo.carbonModifiers, action: action)
            guard hotKey != nil else {
                problem = "\(combo.displayText)는 다른 앱이 쓰고 있어서 등록하지 못했어요. 다른 조합으로 바꿔 주세요."
                return false
            }
            problem = nil
            return true
        case .fnSpace:
            problem = nil
            if FnSpaceHotKey.start(action: action) {
                fnState = .active
                permissionWaitUntil = nil
            } else if PanelShortcut.isTrusted(prompt: promptForPermission) {
                fnState = .failed
            } else {
                fnState = .needsPermission
                if promptForPermission {
                    permissionWaitUntil = Date().addingTimeInterval(10 * 60)
                }
            }
            return true
        }
    }

    /// 어디서든 단축키로 패널 열기를 켜거나 꺼요.
    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        if isRecording {
            stopKeyMonitor()
        }
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        activate(promptForPermission: on && kind == .fnSpace)
        onChange?()
    }

    /// fn + Space와 직접 정한 조합 중에서 골라요.
    func setKind(_ newKind: PanelShortcutKind) {
        guard newKind != kind else { return }
        if isRecording {
            stopKeyMonitor()
        }
        kind = newKind
        defaults.set(newKind.rawValue, forKey: Self.kindKey)
        activate(promptForPermission: newKind == .fnSpace)
        onChange?()
    }

    // MARK: - 손쉬운 사용 권한

    /// 설정 창의 '허용하기': macOS의 허용 창을 띄우고, 허용될 때까지 10분 동안 2초마다 살펴요.
    func requestPermission() {
        permissionWaitUntil = Date().addingTimeInterval(10 * 60)
        if PanelShortcut.isTrusted(prompt: true) {
            refreshPermission()
        }
        updateCheckTimer()
    }

    /// 시스템 설정의 손쉬운 사용 화면을 열어요.
    func openAccessibilitySettings() {
        permissionWaitUntil = Date().addingTimeInterval(10 * 60)
        updateCheckTimer()
        if let url = Self.accessibilitySettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// 허용됐으면 fn + Space를 켜요. (설정 창을 열 때, 앱으로 돌아올 때, 허용을 기다리는 동안 2초마다)
    func refreshPermission() {
        guard isEnabled, kind == .fnSpace, fnState != .active else { return }
        if PanelShortcut.isTrusted(prompt: false) {
            let before = fnState
            activate()
            if fnState != before {
                onChange?()
            }
        } else if let until = permissionWaitUntil, until <= Date() {
            permissionWaitUntil = nil
            updateCheckTimer()
        }
    }

    /// 손쉬운 사용 허용 여부. prompt가 true면 허용되지 않았을 때 macOS의 허용 창을 띄워요.
    nonisolated private static func isTrusted(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// fn + Space를 받는 동안에는 5초마다 허용이 꺼지지 않았는지, 허용을 기다리는 동안에는 2초마다 허용됐는지 살펴요.
    private func updateCheckTimer() {
        let interval: TimeInterval?
        switch fnState {
        case .active:
            interval = 5
        case .needsPermission, .failed:
            interval = (permissionWaitUntil.map { $0 > Date() } ?? false) ? 2 : nil
        case .off:
            interval = nil
        }
        guard interval != checkInterval else { return }
        checkTimer?.invalidate()
        checkTimer = nil
        checkInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // 메인 실행 루프에 붙인 타이머라 메인 스레드에서 불려요.
            MainActor.assumeIsolated {
                self?.check()
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private func check() {
        switch fnState {
        case .active:
            guard !FnSpaceHotKey.canFilterKeyEvents() else { return }
            // 손쉬운 사용 허용이 꺼졌어요. 입력이 막히지 않게 탭을 바로 없애요.
            FnSpaceHotKey.stop()
            fnState = .needsPermission
            updateCheckTimer()
            onChange?()
        case .needsPermission, .failed:
            refreshPermission()
        case .off:
            updateCheckTimer()
        }
    }

    /// 앱으로 돌아올 때와 손쉬운 사용 목록이 바뀔 때 바로 다시 살펴요.
    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check()
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check()
            }
        })
    }

    // MARK: - 직접 정한 조합 녹화

    /// 새 조합 기다리기를 시작해요. 다음에 누르는 조합이 새 단축키가 되고, Esc를 누르면 취소돼요.
    func startRecording() {
        guard !isRecording, isEnabled, kind == .custom else { return }
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

    /// 직접 정한 조합을 기본값(⌃⌥M)으로 되돌려요.
    func resetToStandard() {
        if isRecording {
            stopKeyMonitor()
        }
        change(to: .standard)
    }

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

    /// 새 조합을 저장해요. 직접 정한 조합을 쓰는 중이면 등록해 보고, 안 되면 원래 조합을 그대로 둬요.
    private func change(to newCombo: HotKeyCombo) {
        guard isEnabled, kind == .custom else {
            // 지금은 쓰지 않는 조합이라 저장만 해 둬요. (직접 정한 조합을 고르면 이 조합으로 등록해요)
            combo = newCombo
            problem = nil
            saveCombo()
            onChange?()
            return
        }
        hotKey?.unregister()
        hotKey = nil
        if let registered = GlobalHotKey(keyCode: newCombo.keyCode,
                                         carbonModifiers: newCombo.carbonModifiers,
                                         action: action) {
            hotKey = registered
            combo = newCombo
            problem = nil
            saveCombo()
            onChange?()
        } else {
            activate()
            problem = "\(newCombo.displayText)는 다른 앱이 쓰고 있어서 바꾸지 못했어요. 다른 조합을 눌러 주세요."
        }
    }

    // MARK: - 저장

    private static func loadCombo(from defaults: UserDefaults) -> HotKeyCombo? {
        guard let data = defaults.data(forKey: comboKey),
              let saved = try? JSONDecoder().decode(HotKeyCombo.self, from: data),
              saved.hasRequiredModifier else {
            return nil
        }
        return saved
    }

    private func saveCombo() {
        if let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: Self.comboKey)
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
