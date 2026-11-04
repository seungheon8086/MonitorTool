import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 어디서든 fn + Space를 받아요. (2026-10-25 사용자 요청)
///
/// macOS의 전역 단축키 기능(RegisterEventHotKey)은 ⌘·⌃·⌥·⇧ 네 가지 보조 키만 받아서 fn을 쓸 수 없어요.
/// 그래서 키보드 이벤트 탭(CGEventTap)으로 직접 알아채요. 탭에는 모든 키 입력이 지나가지만, 여기서는
/// 키 번호가 Space인지와 보조 키만 보고 나머지는 손대지 않고 그대로 흘려보내요. 아무것도 저장하지 않아요.
/// fn + Space는 앞에 있는 앱에 띄어쓰기가 들어가지 않게 삼켜요. 입력을 삼키는 탭은 '손쉬운 사용' 권한이 있어야 만들어져요.
enum FnSpaceHotKey {
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?
    private static var action: (() -> Void)?
    /// fn + Space를 삼킨 뒤, 누르고 있는 동안의 반복 입력과 짝이 되는 Space 떼기도 삼키려고 기억해요.
    private static var swallowingSpace = false

    /// 탭을 만들어 받기 시작해요. 손쉬운 사용 권한이 없어서 만들지 못하면 false예요.
    /// - Parameter action: fn + Space를 눌렀을 때 할 일 (패널 열기/닫기)
    static func start(action: @escaping () -> Void) -> Bool {
        stop()
        guard let tap = makeTap() else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // 메인 실행 루프에 붙여서, 탭의 콜백도 메인 스레드에서 불려요.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        self.action = action
        swallowingSpace = false
        return true
    }

    /// 탭을 없애요. 이 뒤로는 키 입력이 이 앱을 거치지 않아요.
    static func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        action = nil
        swallowingSpace = false
    }

    /// 입력을 삼키는 탭을 지금 만들 수 있는지 시험해 봐요. (만들자마자 없애요)
    /// 손쉬운 사용 허용을 껐을 때 AXIsProcessTrusted()는 계속 true를 줄 수 있어서, 이 방법으로 알아채요.
    /// (Apple 개발자 포럼 735204: 허용을 끈 뒤에도 입력을 삼키는 탭이 남아 있으면 입력이 막힐 수 있어요)
    nonisolated static func canFilterKeyEvents() -> Bool {
        let probe = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                      place: .tailAppendEventTap,
                                      options: .defaultTap,
                                      eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                      callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                      userInfo: nil)
        guard let probe else {
            return false
        }
        CFMachPortInvalidate(probe)
        return true
    }

    // MARK: - 탭

    /// C 콜백은 메인 액터에 묶이지 않은(nonisolated) 곳에서 만들어야 해요.
    nonisolated private static func makeTap() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        return CGEvent.tapCreate(tap: .cgSessionEventTap,
                                 place: .headInsertEventTap,
                                 options: .defaultTap,
                                 eventsOfInterest: mask,
                                 callback: { _, type, event, _ in
                                     FnSpaceHotKey.handle(type: type, event: event)
                                 },
                                 userInfo: nil)
    }

    /// 탭이 받은 입력 하나. Space가 아니면 바로 그대로 돌려보내요.
    nonisolated private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 앱이 잠깐 바빠서(예: 디버거로 멈춤) macOS가 탭을 껐어요. 다시 켜요.
            MainActor.assumeIsolated {
                FnSpaceHotKey.reenable()
            }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space) else {
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags.rawValue
        let isDown = type == .keyDown
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // 메인 실행 루프에 붙인 탭이라 메인 스레드에서 불려요. 그 사실을 컴파일러에게 알려 줘요.
        let swallow = MainActor.assumeIsolated {
            FnSpaceHotKey.handleSpace(flags: flags, isDown: isDown, isRepeat: isRepeat)
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Space 입력을 삼킬지 정해요. fn만 함께 눌렀을 때만 패널을 열고 닫아요. (⌘·⌃·⌥·⇧가 같이 눌리면 그대로 흘려보내요)
    private static func handleSpace(flags rawFlags: UInt64, isDown: Bool, isRepeat: Bool) -> Bool {
        guard isDown else {
            // 삼킨 Space의 떼기도 삼켜요. (fn을 먼저 떼도요)
            let wasSwallowing = swallowingSpace
            swallowingSpace = false
            return wasSwallowing
        }
        if isRepeat {
            // 누르고 있는 동안의 반복 입력: 처음 누른 것을 삼켰으면 이것도 삼켜요.
            return swallowingSpace
        }
        let flags = CGEventFlags(rawValue: rawFlags)
        let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard flags.contains(.maskSecondaryFn), flags.isDisjoint(with: otherModifiers) else {
            swallowingSpace = false
            return false
        }
        swallowingSpace = true
        // 탭 안에서는 짧게 끝내야 해서, 패널 열기·닫기는 다음 차례로 미뤄요.
        Task { @MainActor in
            FnSpaceHotKey.action?()
        }
        return true
    }

    private static func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}
