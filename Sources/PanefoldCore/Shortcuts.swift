import Foundation

/// Modifier keys, independent of AppKit and Carbon.
public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    /// In the order macOS prints them: ⌃⌥⇧⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }

    /// From NSEvent.ModifierFlags raw values, as stored in macOS's own shortcut list.
    public init(cocoaFlags: UInt) {
        var m: Modifiers = []
        if cocoaFlags & (1 << 17) != 0 { m.insert(.shift) }
        if cocoaFlags & (1 << 18) != 0 { m.insert(.control) }
        if cocoaFlags & (1 << 19) != 0 { m.insert(.option) }
        if cocoaFlags & (1 << 20) != 0 { m.insert(.command) }
        self = m
    }
}

/// A key and its modifiers. Key codes are macOS virtual key codes (kVK_*), the same on every keyboard layout.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(_ keyCode: UInt32, _ modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isFunctionKey: Bool { KeyCodes.functionKeys.contains(keyCode) }

    /// A shortcut must keep ⌃, ⌥ or ⌘ so typing still works. F-keys may go alone.
    public var isValidShortcut: Bool {
        isFunctionKey || !modifiers.isDisjoint(with: [.control, .option, .command])
    }

    /// ⌥ with a letter types a character (⌥R types ®), so such a combo would steal typing.
    public var typesCharacter: Bool {
        modifiers.isSubset(of: [.option, .shift]) && modifiers.contains(.option) && KeyCodes.typing.contains(keyCode)
    }

    public func display(keyName: (UInt32) -> String = KeyCodes.name) -> String {
        modifiers.symbols + keyName(keyCode)
    }
}

public enum KeyCodes {
    public static let a: UInt32 = 0x00, s: UInt32 = 0x01, d: UInt32 = 0x02, f: UInt32 = 0x03
    public static let z: UInt32 = 0x06, r: UInt32 = 0x0F, t: UInt32 = 0x11, p: UInt32 = 0x23
    public static let one: UInt32 = 0x12, two: UInt32 = 0x13, three: UInt32 = 0x14, four: UInt32 = 0x15, five: UInt32 = 0x17
    public static let equal: UInt32 = 0x18, minus: UInt32 = 0x1B, zero: UInt32 = 0x1D
    public static let rightBracket: UInt32 = 0x1E, leftBracket: UInt32 = 0x21
    public static let returnKey: UInt32 = 0x24, tab: UInt32 = 0x30, space: UInt32 = 0x31, grave: UInt32 = 0x32
    public static let delete: UInt32 = 0x33, escape: UInt32 = 0x35, slash: UInt32 = 0x2C
    public static let left: UInt32 = 0x7B, right: UInt32 = 0x7C, down: UInt32 = 0x7D, up: UInt32 = 0x7E

    public static let digits: [UInt32] = [one, two, three, four, five]

    static let names: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
        0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
        0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "Esc", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]

    public static let functionKeys: Set<UInt32> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                                                   0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
    /// F-keys offered as free keys, least likely to be taken first.
    public static let suggestedFunctionKeys: [UInt32] = [0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x60, 0x61, 0x62, 0x64, 0x65]
    /// Keys that type a character when pressed with ⌥.
    static let typing: Set<UInt32> = Set(names.keys).subtracting(functionKeys).subtracting([0x24, 0x30, 0x31, 0x33, 0x35, 0x75, 0x7B, 0x7C, 0x7D, 0x7E, 0x73, 0x77, 0x74, 0x79])

    public static func name(_ code: UInt32) -> String { names[code] ?? "Key \(code)" }
}

/// Every action that can have a shortcut.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case toggleTiling, cheatSheet
    case swapLeft, swapRight, swapUp, swapDown
    case makePrimary, nextWindow, previousWindow, nextInStack, previousInStack, tabView
    case grow, shrink, resetSizes
    case layoutGrid, layoutColumns, layoutRows, layoutSide
    case count1, count2, count3, count4, count5
    case float, alwaysFloat, focusMode, noPeek, cleanSpace, retile

    public enum Group: String, CaseIterable, Sendable { case general, move, activate, size, layout, more }

    public var group: Group {
        switch self {
        case .toggleTiling, .cheatSheet: .general
        case .swapLeft, .swapRight, .swapUp, .swapDown: .move
        case .makePrimary, .nextWindow, .previousWindow, .nextInStack, .previousInStack, .tabView: .activate
        case .grow, .shrink, .resetSizes: .size
        case .layoutGrid, .layoutColumns, .layoutRows, .layoutSide, .count1, .count2, .count3, .count4, .count5: .layout
        case .float, .alwaysFloat, .focusMode, .noPeek, .cleanSpace, .retile: .more
        }
    }

    public var isCount: Bool { countValue != nil }

    public var countValue: Int? {
        switch self {
        case .count1: 1
        case .count2: 2
        case .count3: 3
        case .count4: 4
        case .count5: 5
        default: nil
        }
    }

    public var layoutValue: LayoutKind? {
        switch self {
        case .layoutGrid: .grid
        case .layoutColumns: .columns
        case .layoutRows: .rows
        case .layoutSide: .side
        default: nil
        }
    }

    public static func count(_ n: Int) -> ShortcutAction {
        [.count1, .count2, .count3, .count4, .count5][max(1, min(5, n)) - 1]
    }
}

public enum ShortcutPrefix: String, CaseIterable, Codable, Sendable {
    case controlOption, optionCommand, controlShift

    public var modifiers: Modifiers {
        switch self {
        case .controlOption: [.control, .option]
        case .optionCommand: [.option, .command]
        case .controlShift: [.control, .shift]
        }
    }

    /// Added for the four layouts: ⇧, or ⌥ when the prefix already has ⇧.
    var layoutExtra: Modifiers { modifiers.contains(.shift) ? .option : .shift }
    /// Added for window counts: ⌘, or ⌃ when the prefix already has ⌘.
    var countExtra: Modifiers { modifiers.contains(.command) ? .control : .command }
}

/// Every shortcut: each action's own key with the prefix, plus the user's changes.
public struct ShortcutBindings: Codable, Equatable, Sendable {
    public var prefix: ShortcutPrefix = .controlOption
    /// Keys the user picked for an action. They don't move when the prefix changes.
    public var custom: [ShortcutAction: KeyCombo] = [:]
    /// Actions the user turned off.
    public var disabled: Set<ShortcutAction> = []

    public init(prefix: ShortcutPrefix = .controlOption) { self.prefix = prefix }

    public func defaultCombo(_ action: ShortcutAction) -> KeyCombo {
        let p = prefix.modifiers
        switch action {
        case .toggleTiling: return KeyCombo(KeyCodes.t, p)
        case .cheatSheet: return KeyCombo(KeyCodes.slash, p)
        case .swapLeft: return KeyCombo(KeyCodes.left, p)
        case .swapRight: return KeyCombo(KeyCodes.right, p)
        case .swapUp: return KeyCombo(KeyCodes.up, p)
        case .swapDown: return KeyCombo(KeyCodes.down, p)
        case .makePrimary: return KeyCombo(KeyCodes.returnKey, p)
        case .nextWindow: return KeyCombo(KeyCodes.rightBracket, p)
        case .previousWindow: return KeyCombo(KeyCodes.leftBracket, p)
        case .nextInStack: return KeyCombo(KeyCodes.grave, p)
        case .previousInStack: return KeyCombo(KeyCodes.grave, p.union(.shift) == p ? p.union(.option) : p.union(.shift))
        case .tabView: return KeyCombo(KeyCodes.tab, .option)
        case .grow: return KeyCombo(KeyCodes.equal, p)
        case .shrink: return KeyCombo(KeyCodes.minus, p)
        case .resetSizes: return KeyCombo(KeyCodes.zero, p)
        case .layoutGrid: return KeyCombo(KeyCodes.one, p.union(prefix.layoutExtra))
        case .layoutColumns: return KeyCombo(KeyCodes.two, p.union(prefix.layoutExtra))
        case .layoutRows: return KeyCombo(KeyCodes.three, p.union(prefix.layoutExtra))
        case .layoutSide: return KeyCombo(KeyCodes.four, p.union(prefix.layoutExtra))
        case .count1, .count2, .count3, .count4, .count5:
            return KeyCombo(KeyCodes.digits[action.countValue! - 1], p.union(prefix.countExtra))
        case .float: return KeyCombo(KeyCodes.f, p)
        case .alwaysFloat: return KeyCombo(KeyCodes.f, p.union(.shift) == p ? p.union(.option) : p.union(.shift))
        case .focusMode: return KeyCombo(KeyCodes.z, p)
        case .noPeek: return KeyCombo(KeyCodes.d, p)
        case .cleanSpace: return KeyCombo(KeyCodes.p, p)
        case .retile: return KeyCombo(KeyCodes.r, p)
        }
    }

    /// The keys an action uses now, or nil if it's off.
    public func combo(_ action: ShortcutAction) -> KeyCombo? {
        if disabled.contains(action) { return nil }
        if action.isCount, let base = custom[.count1] {
            return KeyCombo(KeyCodes.digits[action.countValue! - 1], base.modifiers)
        }
        return custom[action] ?? defaultCombo(action)
    }

    public func isCustom(_ action: ShortcutAction) -> Bool {
        action.isCount ? custom[.count1] != nil : custom[action] != nil
    }

    /// Sets new keys. Window counts change together: only the modifiers of the keys pressed count.
    public mutating func set(_ action: ShortcutAction, to combo: KeyCombo?) {
        let key: ShortcutAction = action.isCount ? .count1 : action
        let affected: [ShortcutAction] = action.isCount ? [.count1, .count2, .count3, .count4, .count5] : [action]
        guard let combo else {
            affected.forEach { disabled.insert($0) }
            return
        }
        affected.forEach { disabled.remove($0) }
        custom[key] = action.isCount ? KeyCombo(KeyCodes.one, combo.modifiers) : combo
    }

    public mutating func reset(_ action: ShortcutAction) {
        let affected: [ShortcutAction] = action.isCount ? [.count1, .count2, .count3, .count4, .count5] : [action]
        custom[action.isCount ? .count1 : action] = nil
        affected.forEach { disabled.remove($0) }
    }

    public mutating func resetAll() {
        custom.removeAll()
        disabled.removeAll()
        prefix = .controlOption
    }

    /// Every active action and its keys.
    public var all: [(ShortcutAction, KeyCombo)] {
        ShortcutAction.allCases.compactMap { a in combo(a).map { (a, $0) } }
    }

    /// Other actions already using `combo`. Tab View's reverse direction (the same keys with ⇧) counts as Tab View.
    public func actions(using combo: KeyCombo, except: ShortcutAction? = nil) -> [ShortcutAction] {
        all.filter { action, c in
            guard action != except, !(except?.isCount == true && action.isCount) else { return false }
            if c == combo { return true }
            if action == .tabView, KeyCombo(c.keyCode, c.modifiers.union(.shift)) == combo { return true }
            return false
        }.map(\.0)
    }

    /// Free keys to offer instead of `combo`: the same key with other modifiers first, then F-keys.
    public func suggestions(for combo: KeyCombo, isTaken: (KeyCombo) -> Bool, limit: Int = 3) -> [KeyCombo] {
        let sets: [Modifiers] = [[.control, .option], [.option, .command], [.control, .shift], [.control, .command],
                                 [.control, .option, .command], [.control, .option, .shift], [.option, .shift, .command]]
        var out: [KeyCombo] = []
        for m in sets where m != combo.modifiers {
            let c = KeyCombo(combo.keyCode, m)
            if !isTaken(c), actions(using: c).isEmpty { out.append(c) }
            if out.count == limit { return out }
        }
        for f in KeyCodes.suggestedFunctionKeys {
            let c = KeyCombo(f, [])
            if !isTaken(c), actions(using: c).isEmpty { out.append(c) }
            if out.count == limit { break }
        }
        return out
    }

    enum CodingKeys: String, CodingKey { case prefix, custom, disabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prefix = (try? c.decode(ShortcutPrefix.self, forKey: .prefix)) ?? .controlOption
        let raw = (try? c.decode([String: KeyCombo].self, forKey: .custom)) ?? [:]
        custom = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in ShortcutAction(rawValue: k).map { ($0, v) } })
        disabled = Set(((try? c.decode([String].self, forKey: .disabled)) ?? []).compactMap(ShortcutAction.init(rawValue:)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(prefix, forKey: .prefix)
        try c.encode(Dictionary(uniqueKeysWithValues: custom.map { ($0.key.rawValue, $0.value) }), forKey: .custom)
        try c.encode(disabled.map(\.rawValue).sorted(), forKey: .disabled)
    }
}

/// macOS's own keyboard shortcuts (screenshots, Spotlight, Mission Control…), read from its preferences.
public enum SystemShortcuts {
    /// Parses the `AppleSymbolicHotKeys` dictionary of com.apple.symbolichotkeys.
    public static func parse(_ dict: [String: Any]) -> Set<KeyCombo> {
        var out: Set<KeyCombo> = []
        for case let entry as [String: Any] in dict.values {
            guard (entry["enabled"] as? Bool) ?? (entry["enabled"] as? Int == 1),
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let code = (params[1] as? NSNumber)?.intValue, code >= 0, code != 65535,
                  let flags = (params[2] as? NSNumber)?.uintValue else { continue }
            out.insert(KeyCombo(UInt32(code), Modifiers(cocoaFlags: flags)))
        }
        return out
    }
}
