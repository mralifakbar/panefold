import AppKit
import Carbon.HIToolbox
import PanefoldCore

/// Global shortcuts through Carbon's hot keys. macOS reports only these combinations, nothing else you type,
/// and needs no Input Monitoring permission for them.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    /// Combos another app already holds.
    private(set) var failed: Set<KeyCombo> = []

    private init() {}

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotkeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Registers a combo. Returns a token for `unregister`, or nil if the keys are taken.
    @discardableResult
    func register(_ combo: KeyCombo, handler: @escaping () -> Void) -> UInt32? {
        install()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, Self.carbonModifiers(combo.modifiers),
                                         EventHotKeyID(signature: OSType(0x5041_4E45), id: id), // "PANE"
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            failed.insert(combo)
            return nil
        }
        failed.remove(combo)
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    func unregisterAll(_ ids: [UInt32]) { ids.forEach(unregister) }

    func clearFailures() { failed.removeAll() }

    static func carbonModifiers(_ m: Modifiers) -> UInt32 {
        var out: UInt32 = 0
        if m.contains(.command) { out |= UInt32(cmdKey) }
        if m.contains(.option) { out |= UInt32(optionKey) }
        if m.contains(.control) { out |= UInt32(controlKey) }
        if m.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
        var m: Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    /// The key's name on the current keyboard layout, so an AZERTY keyboard shows its own letters.
    static func keyName(_ code: UInt32) -> String {
        if KeyCodes.functionKeys.contains(code) || [KeyCodes.left, KeyCodes.right, KeyCodes.up, KeyCodes.down,
                                                     KeyCodes.returnKey, KeyCodes.tab, KeyCodes.space, KeyCodes.delete, KeyCodes.escape].contains(code) {
            return KeyCodes.name(code)
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return KeyCodes.name(code) }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return KeyCodes.name(code) }
        let s = String(utf16CodeUnits: chars, count: length).uppercased()
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? KeyCodes.name(code) : s
    }
}

extension KeyCombo {
    var label: String { display(keyName: HotkeyCenter.keyName) }
}
