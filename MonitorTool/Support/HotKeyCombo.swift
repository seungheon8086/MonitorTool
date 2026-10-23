import Carbon.HIToolbox
import Foundation

/// 전역 단축키 하나예요. (예: ⌃⌥M) 키보드의 물리 키 번호와 보조 키를 함께 저장해요.
nonisolated struct HotKeyCombo: Codable, Hashable, Sendable {
    /// 물리 키 번호 (Carbon 가상 키 코드, 예: M = kVK_ANSI_M). 입력 언어를 바꿔도 같은 자리의 키예요.
    var keyCode: UInt32
    /// 보조 키의 Carbon 값 (controlKey·optionKey·shiftKey·cmdKey를 합친 값)
    var carbonModifiers: UInt32
    /// 화면에 보여줄 키 이름 (예: M, F5, ←)
    var keyName: String

    /// 기본 단축키 ⌃⌥M
    static let standard = HotKeyCombo(keyCode: UInt32(kVK_ANSI_M),
                                      carbonModifiers: UInt32(controlKey | optionKey),
                                      keyName: "M")

    init(keyCode: UInt32, carbonModifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyName = keyName
    }

    /// 누른 키로 만들어요. 특수 키는 이름표에서 찾고, 나머지는 입력된 글자를 대문자로 써요.
    init(keyCode: UInt32, carbonModifiers: UInt32, characters: String) {
        let typed = characters.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let name = Self.specialKeys[Int(keyCode)]?.name ?? (typed.isEmpty ? "키 \(keyCode)" : typed)
        self.init(keyCode: keyCode, carbonModifiers: carbonModifiers, keyName: name)
    }

    /// '⌃⌥M' (macOS 순서: ⌃ ⌥ ⇧ ⌘)
    var displayText: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    /// ⌃·⌥·⌘ 중 하나 이상이 들어 있는지. ⇧만 붙은 조합은 글자 입력과 겹쳐서 단축키로 쓰지 않아요.
    var hasRequiredModifier: Bool {
        carbonModifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// 메뉴 항목에 보여줄 키 (NSMenuItem.keyEquivalent). 보여줄 수 없는 키면 빈 글자예요.
    var menuKeyEquivalent: String {
        if let special = Self.specialKeys[Int(keyCode)] {
            return special.menu
        }
        return keyName.count == 1 ? keyName.lowercased() : ""
    }

    /// 이름으로 보여줄 특수 키: 키 번호 → (화면 이름, 메뉴 키)
    private static let specialKeys: [Int: (name: String, menu: String)] = [
        kVK_Space: ("Space", " "),
        kVK_Return: ("↩", "\r"),
        kVK_Tab: ("⇥", "\t"),
        kVK_Delete: ("⌫", "\u{8}"),
        kVK_ForwardDelete: ("⌦", "\u{7F}"),
        kVK_LeftArrow: ("←", "\u{F702}"),
        kVK_RightArrow: ("→", "\u{F703}"),
        kVK_UpArrow: ("↑", "\u{F700}"),
        kVK_DownArrow: ("↓", "\u{F701}"),
        kVK_F1: ("F1", "\u{F704}"),
        kVK_F2: ("F2", "\u{F705}"),
        kVK_F3: ("F3", "\u{F706}"),
        kVK_F4: ("F4", "\u{F707}"),
        kVK_F5: ("F5", "\u{F708}"),
        kVK_F6: ("F6", "\u{F709}"),
        kVK_F7: ("F7", "\u{F70A}"),
        kVK_F8: ("F8", "\u{F70B}"),
        kVK_F9: ("F9", "\u{F70C}"),
        kVK_F10: ("F10", "\u{F70D}"),
        kVK_F11: ("F11", "\u{F70E}"),
        kVK_F12: ("F12", "\u{F70F}"),
    ]
}
