import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var displayText: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func from(event: NSEvent) -> Shortcut? {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return nil }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    private static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "空格",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9"
        ]
        return names[code] ?? "键码\(code)"
    }
}

enum ShortcutDefaults {
    static let modifier = UInt32(controlKey | optionKey)
    static let values: [WindowAction: Shortcut] = [
        .leftHalf: .init(keyCode: UInt32(kVK_LeftArrow), modifiers: modifier),
        .rightHalf: .init(keyCode: UInt32(kVK_RightArrow), modifiers: modifier),
        .topHalf: .init(keyCode: UInt32(kVK_UpArrow), modifiers: modifier),
        .bottomHalf: .init(keyCode: UInt32(kVK_DownArrow), modifiers: modifier),
        .topLeft: .init(keyCode: UInt32(kVK_ANSI_U), modifiers: modifier),
        .topRight: .init(keyCode: UInt32(kVK_ANSI_I), modifiers: modifier),
        .bottomLeft: .init(keyCode: UInt32(kVK_ANSI_J), modifiers: modifier),
        .bottomRight: .init(keyCode: UInt32(kVK_ANSI_K), modifiers: modifier),
        .leftThird: .init(keyCode: UInt32(kVK_ANSI_1), modifiers: modifier),
        .centerThird: .init(keyCode: UInt32(kVK_ANSI_2), modifiers: modifier),
        .rightThird: .init(keyCode: UInt32(kVK_ANSI_3), modifiers: modifier),
        .maximize: .init(keyCode: UInt32(kVK_ANSI_M), modifiers: modifier),
        .center: .init(keyCode: UInt32(kVK_ANSI_C), modifiers: modifier),
        .restore: .init(keyCode: UInt32(kVK_ANSI_R), modifiers: modifier),
        .nextDisplay: .init(keyCode: UInt32(kVK_ANSI_N), modifiers: modifier),
        .previousDisplay: .init(keyCode: UInt32(kVK_ANSI_P), modifiers: modifier)
    ]
}

final class ShortcutStore {
    private let defaults = UserDefaults.standard
    private(set) var shortcuts: [WindowAction: Shortcut] = [:]

    init() { load() }

    func set(_ shortcut: Shortcut, for action: WindowAction) {
        shortcuts[action] = shortcut
        save()
    }

    func conflictingAction(for shortcut: Shortcut, excluding action: WindowAction) -> WindowAction? {
        shortcuts.first { $0.key != action && $0.value == shortcut }?.key
    }

    func reset() {
        shortcuts = ShortcutDefaults.values
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: "shortcuts.v1"),
              let raw = try? JSONDecoder().decode([String: Shortcut].self, from: data) else {
            shortcuts = ShortcutDefaults.values
            return
        }
        shortcuts = ShortcutDefaults.values
        for (key, value) in raw {
            if let action = WindowAction(rawValue: key), action.columnLayout == nil { shortcuts[action] = value }
        }
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: "shortcuts.v1") }
    }
}
