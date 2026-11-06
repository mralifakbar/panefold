import AppKit
import SwiftUI
import PanefoldCore

/// Settings → Keyboard: every shortcut, editable, with what already uses the keys and free keys to pick.
struct KeyboardPage: View {
    @EnvironmentObject var wm: WindowManager
    @ObservedObject private var hotkeys = HotkeyBinder.shared
    @State private var recording: ShortcutAction?

    var body: some View {
        Section2(title: String(localized: "Keyboard shortcuts")) {
            SettingRow(title: String(localized: "Keyboard shortcuts"), detail: String(localized: "Arrange windows from the keyboard. They stay listed when off, so you can still learn them.")) {
                Toggle("", isOn: $wm.prefs.shortcutsEnabled).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: String(localized: "Shortcut prefix"), detail: String(localized: "The keys every shortcut starts with. Shortcuts you changed keep their keys.")) {
                Picker("", selection: $wm.prefs.shortcuts.prefix) {
                    Text("⌃⌥").tag(ShortcutPrefix.controlOption)
                    Text("⌥⌘").tag(ShortcutPrefix.optionCommand)
                    Text("⌃⇧").tag(ShortcutPrefix.controlShift)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow(title: String(localized: "Shortcut cheat sheet")) {
                Button(String(localized: "Show")) { CheatSheet.shared.show() }
            }
            if !hotkeys.unavailable.isEmpty {
                ActionCard(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           text: String(localized: "Another app already uses \(hotkeys.unavailable.count) of these shortcuts, so Panefold can't. They're dimmed below: give them other keys, or pick another prefix."))
            }
        }
        ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
            Section2(title: ShortcutText.groupName(group)) {
                ForEach(ShortcutAction.allCases.filter { $0.group == group && !($0.isCount && $0 != .count1) }, id: \.self) { action in
                    row(action)
                }
            }
        }
        HStack {
            Spacer()
            Button(String(localized: "Reset All")) { wm.prefs.shortcuts.resetAll() }
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let combo = wm.prefs.shortcuts.combo(action)
        let dimmed = hotkeys.unavailable.contains(action)
        let macOS = hotkeys.leftToMacOS.contains(action)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.isCount ? String(localized: "Tile 1 to 5 windows (the numbers change together)") : ShortcutText.name(action))
                    .opacity(dimmed ? 0.5 : 1)
                if macOS { Text("Left to macOS").font(.caption2).foregroundStyle(.orange) }
                if dimmed { Text("In use by another app").font(.caption2).foregroundStyle(.orange) }
                Spacer()
                if wm.prefs.shortcuts.isCustom(action) || wm.prefs.shortcuts.disabled.contains(action) {
                    Button { wm.prefs.shortcuts.reset(action) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help(String(localized: "Bring back its own keys"))
                }
                ShortcutField(combo: combo, display: action.isCount ? combo.map { $0.modifiers.symbols + "1–5" } : nil,
                              recording: Binding(get: { recording == action }, set: { recording = $0 ? action : nil }),
                              requireHold: action == .tabView, owner: action) { new in
                    wm.prefs.shortcuts.set(action, to: new)
                }
            }
        }
    }
}

/// Click, then press keys. Esc cancels, Delete turns the shortcut off.
/// Warns about what already uses the keys and offers free ones.
struct ShortcutField: View {
    let combo: KeyCombo?
    var display: String?
    @Binding var recording: Bool
    var requireHold = false
    var owner: ShortcutAction?
    let onChange: (KeyCombo?) -> Void

    @EnvironmentObject var wm: WindowManager
    @State private var monitor: Any?
    @State private var pending: KeyCombo?
    @State private var warning: String?
    @State private var suggestions: [KeyCombo] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 6) {
                    Text(recording ? String(localized: "Press keys…") : (display ?? combo?.label ?? String(localized: "Off")))
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundStyle(combo == nil && !recording ? .secondary : .primary)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(minWidth: 96)
                .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Color.accentColor : .clear))
            }
            .buttonStyle(.plain)
            if let warning, let pending {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(warning).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                    HStack {
                        Button(String(localized: "Use Anyway")) { commit(pending) }.controlSize(.small)
                        ForEach(suggestions, id: \.self) { s in
                            Button(s.label) { commit(s) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        warning = nil
        pending = nil
        HotkeyBinder.shared.paused = true
        // Read only inside Panefold's Settings window, only while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false }
        HotkeyBinder.shared.paused = false
    }

    private func handle(_ e: NSEvent) {
        let code = UInt32(e.keyCode)
        let mods = HotkeyCenter.modifiers(e.modifierFlags)
        if code == KeyCodes.escape, mods.isEmpty {
            stop()
            return
        }
        if code == KeyCodes.delete || code == 0x75, mods.isEmpty {
            onChange(nil)
            stop()
            return
        }
        let new = KeyCombo(code, mods)
        guard new.isValidShortcut else {
            NSSound.beep()
            return
        }
        if requireHold, new.modifiers.isDisjoint(with: [.option, .command, .control]) {
            NSSound.beep()
            return
        }
        stop()
        if let problem = conflict(new) {
            pending = new
            warning = problem
            suggestions = wm.prefs.shortcuts.suggestions(for: new, isTaken: { c in
                SystemState.systemShortcuts().contains(c) || HotkeyCenter.shared.failed.contains(c) || c.typesCharacter
            })
        } else {
            commit(new)
        }
    }

    private func commit(_ c: KeyCombo) {
        if let owner {
            for other in wm.prefs.shortcuts.actions(using: c, except: owner) { wm.prefs.shortcuts.set(other, to: nil) }
        }
        onChange(c)
        warning = nil
        pending = nil
    }

    /// What already uses these keys: another Panefold shortcut, macOS, typing, or an open app's menu.
    private func conflict(_ c: KeyCombo) -> String? {
        if let other = wm.prefs.shortcuts.actions(using: c, except: owner).first {
            return String(localized: "Already “\(ShortcutText.name(other))”. Using it here turns that one off.")
        }
        if SystemState.systemShortcuts().contains(c) { return String(localized: "macOS uses these keys for one of its own shortcuts.") }
        if c.typesCharacter { return String(localized: "These keys type a character, so typing would stop working for it.") }
        if let item = MenuShortcuts.find(c) { return String(localized: "\(item.app) uses these keys for “\(item.title)”. A Panefold shortcut works in every app.") }
        return nil
    }
}

/// Looks through open apps' menus for a key combination. Read through Accessibility, only while recording;
/// kept in memory, never stored.
enum MenuShortcuts {
    static func find(_ combo: KeyCombo) -> (app: String, title: String)? {
        let own = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != own {
            let ax = AX.app(app.processIdentifier)
            guard let bar: AXUIElement = ax.value(kAXMenuBarAttribute) else { continue }
            if let hit = search(bar, combo, depth: 0) { return (app.localizedName ?? "", hit) }
        }
        return nil
    }

    private static func search(_ e: AXUIElement, _ combo: KeyCombo, depth: Int) -> String? {
        guard depth < 4 else { return nil }
        let children: [AXUIElement] = e.value(kAXChildrenAttribute) ?? []
        for child in children {
            if let char: String = child.value(kAXMenuItemCmdCharAttribute), !char.isEmpty {
                let mods: Int = child.value(kAXMenuItemCmdModifiersAttribute) ?? 0
                // AX menu modifiers: ⌘ is implied unless bit 3 is set; 1 = ⇧, 2 = ⌥, 4 = ⌃.
                var m: Modifiers = []
                if mods & 8 == 0 { m.insert(.command) }
                if mods & 1 != 0 { m.insert(.shift) }
                if mods & 2 != 0 { m.insert(.option) }
                if mods & 4 != 0 { m.insert(.control) }
                if m == combo.modifiers, char.uppercased() == HotkeyCenter.keyName(combo.keyCode).uppercased() {
                    return child.title ?? char
                }
            }
            if let hit = search(child, combo, depth: depth + 1) { return hit }
        }
        return nil
    }
}
