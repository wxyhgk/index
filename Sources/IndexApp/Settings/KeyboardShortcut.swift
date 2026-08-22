import AppKit
import Carbon.HIToolbox

/// 一个全局快捷键的定义。存的是虚拟键码 + Carbon 修饰键掩码，
/// 因为 `RegisterEventHotKey` 只认这两样。
struct KeyboardShortcut: Codable, Equatable {

    var keyCode: UInt32
    /// Carbon 掩码（cmdKey / shiftKey / optionKey / controlKey）。
    var modifiers: UInt32

    static let captureDefault = KeyboardShortcut(
        keyCode: 0,                                    // A
        modifiers: UInt32(controlKey) | UInt32(cmdKey)
    )
    static let galleryDefault = KeyboardShortcut(
        keyCode: 5,                                    // G
        modifiers: UInt32(controlKey) | UInt32(cmdKey)
    )
    static let delayedCaptureDefault = KeyboardShortcut(
        keyCode: 2,                                    // D
        modifiers: UInt32(controlKey) | UInt32(cmdKey)
    )
    static let recordingDefault = KeyboardShortcut(
        keyCode: 15,                                   // R
        modifiers: UInt32(controlKey) | UInt32(cmdKey)
    )
    static let scrollCaptureDefault = KeyboardShortcut(
        keyCode: 1,                                    // S
        modifiers: UInt32(controlKey) | UInt32(cmdKey)
    )
    static let moleculePinDefault = KeyboardShortcut(
        keyCode: 46,                                   // M
        modifiers: UInt32(controlKey) | UInt32(cmdKey)
    )
    static let clipboardHistoryDefault = KeyboardShortcut(
        keyCode: 9,                                    // V
        modifiers: UInt32(shiftKey) | UInt32(cmdKey)
    )
    static let searchPanelDefault = KeyboardShortcut(
        keyCode: 49,                                   // 空格
        modifiers: UInt32(optionKey)
    )
    static let quickNoteDefault = KeyboardShortcut(
        keyCode: 45,                                   // N
        modifiers: UInt32(controlKey) | UInt32(cmdKey)
    )
    static let agentDefault = KeyboardShortcut(
        keyCode: 0,                                    // A
        modifiers: UInt32(shiftKey) | UInt32(cmdKey)
    )

    /// 至少要有一个修饰键，否则会把普通打字全劫走。
    var isValid: Bool { modifiers != 0 }

    // MARK: - 与 AppKit 互转

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.keyCode = UInt32(event.keyCode)
        var mask: UInt32 = 0
        if event.modifierFlags.contains(.command)  { mask |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift)    { mask |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option)   { mask |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control)  { mask |= UInt32(controlKey) }
        self.modifiers = mask
    }

    // MARK: - 展示

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { text += "⌘" }
        text += Self.keyName(for: keyCode)
        return text
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        50: "`",
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "键\(keyCode)"
    }
}
