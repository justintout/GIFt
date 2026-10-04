import AppKit
import Carbon.HIToolbox

/// A key combination, stored the way Carbon wants it so it can be handed to `RegisterEventHotKey`
/// without translation.
struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Command-Escape: the deliberate counterpart to the bare Escape that discards a recording.
    static let `default` = KeyboardShortcut(
        keyCode: UInt32(kVK_Escape),
        modifiers: UInt32(cmdKey)
    )

    /// A bare key would be swallowed system-wide, so at least one modifier is required.
    var isValid: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey) != 0
    }

    var displayString: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Self.name(forKeyCode: keyCode)
    }

    /// Keys the layout translates to invisible control characters, named with the symbols macOS
    /// menus use.
    private static let specialKeyNames: [Int: String] = [
        kVK_Escape: "⎋", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    /// Reads the key's name out of the current keyboard layout, so the label follows a user who is
    /// not on a US layout.
    static func name(forKeyCode keyCode: UInt32) -> String {
        if let name = specialKeyNames[Int(keyCode)] {
            return name
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let layoutData = unsafeBitCast(layoutPointer, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    /// Builds a shortcut from an AppKit event, translating its modifier flags into Carbon's.
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var carbon: UInt32 = 0
        if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        modifiers = carbon
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
