import AppKit
import Carbon.HIToolbox

/// 다른 앱을 쓰는 중에도 동작하는 전역 단축키예요.
/// Carbon의 RegisterEventHotKey를 써서 '손쉬운 사용' 권한 없이 동작해요.
final class GlobalHotKey {
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// 단축키를 등록해요. 다른 앱이 이미 쓰는 조합이라 등록에 실패하면 nil이에요.
    /// - Parameters:
    ///   - keyCode: 키 코드 (예: `kVK_ANSI_M`)
    ///   - carbonModifiers: 함께 누를 보조 키의 Carbon 값 (`controlKey`·`optionKey`·`shiftKey`·`cmdKey`를 합친 값)
    ///   - action: 단축키를 눌렀을 때 할 일
    init?(keyCode: UInt32, carbonModifiers: UInt32, action: @escaping () -> Void) {
        guard Self.installEventHandlerIfNeeded() else { return nil }

        id = Self.nextID
        Self.nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return nil }

        hotKeyRef = ref
        Self.actions[id] = action
    }

    /// 단축키 등록을 해제해요. 단축키를 바꿀 때 이전 단축키를 먼저 풀어 줘요.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        Self.actions[id] = nil
    }

    // MARK: - 보조 키 변환

    /// NSEvent의 보조 키 → Carbon 값 (키 입력을 받아 새 단축키를 만들 때 써요)
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// Carbon 값 → NSEvent의 보조 키 (메뉴에 단축키를 보여줄 때 써요)
    static func modifierFlags(fromCarbon modifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    // MARK: - Carbon 이벤트 처리

    /// 등록된 단축키 번호 → 실행할 동작
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var isEventHandlerInstalled = false

    /// 이 앱의 단축키라는 표시로 쓰는 4글자 코드 "MNTR"
    nonisolated private static var signature: OSType { 0x4D4E_5452 }

    private static func installEventHandlerIfNeeded() -> Bool {
        if !isEventHandlerInstalled {
            isEventHandlerInstalled = (installEventHandler() == noErr)
        }
        return isEventHandlerInstalled
    }

    /// Carbon 콜백은 C 함수라서, 메인 액터에 묶이지 않은(nonisolated) 곳에서 만들어야 해요.
    nonisolated private static func installEventHandler() -> OSStatus {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            GlobalHotKey.handleHotKeyEvent(event)
        }, 1, &eventType, nil, nil)
    }

    nonisolated private static func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &hotKeyID)
        guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
            return OSStatus(eventNotHandledErr)
        }

        let id = hotKeyID.id
        // Carbon은 이 콜백을 메인 스레드에서 불러요. 그 사실을 컴파일러에게 알려 주고 동작을 실행해요.
        MainActor.assumeIsolated {
            GlobalHotKey.performAction(for: id)
        }
        return noErr
    }

    private static func performAction(for id: UInt32) {
        actions[id]?()
    }
}
