import AppKit
import SwiftUI
import PanefoldCore

/// What opens from the menu bar icon: status, the screen under the pointer, and the switches used most.
struct MenuBarPanel: View {
    @EnvironmentObject var wm: WindowManager
    @ObservedObject private var hotkeys = HotkeyBinder.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var setupRunner = SetupRunner.shared
    @State private var naming = false
    @State private var setupName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            cards
            if wm.status.isWorking, let screen = wm.pointerScreen {
                preview(screen)
                windowsOnThisScreen(screen)
                Divider()
                switches
                Divider()
                modes
                if let app = wm.frontApp, let bid = app.bundleIdentifier {
                    Toggle(isOn: Binding(get: { wm.isAppTiled(bid) }, set: { wm.setAppTiled(bid, name: app.localizedName ?? bid, $0) })) {
                        Label(String(localized: "Tile \(app.localizedName ?? bid)"), systemImage: "app.badge.checkmark")
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }
                Divider()
                setups
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Header and cards

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image(wm.prefs.iconStyle, size: 64)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Panefold").font(.headline)
                HStack(spacing: 6) {
                    StatusDot(status: wm.status)
                    Text(wm.status.text).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $wm.prefs.tilingEnabled).toggleStyle(.switch).labelsHidden()
                .help(String(localized: "Automatic tiling"))
        }
    }

    @ViewBuilder
    private var cards: some View {
        if wm.status == .needsAccess {
            ActionCard(symbol: "lock.shield", tint: .red, text: String(localized: "Panefold needs Accessibility access to arrange windows."),
                       button: String(localized: "Grant Access")) {
                _ = AX.isTrusted(prompt: true)
                SystemState.openAccessibilitySettings()
            }
        } else if wm.status == .waitingForSetup {
            ActionCard(symbol: "sparkles", tint: .orange, text: String(localized: "Finish the welcome tour to start tiling."),
                       button: String(localized: "Continue")) { Windows.shared.showOnboarding() }
        }
        if wm.secureInput {
            ActionCard(symbol: "keyboard.badge.ellipsis", tint: .orange,
                       text: String(localized: "Another app is using Secure Input (a password field, say). Shortcuts are paused until it's done."))
        }
        if let update = updater.available {
            ActionCard(symbol: "arrow.down.circle", tint: .blue, text: String(localized: "Panefold \(update.version) is available."),
                       button: String(localized: "See What's New")) { NSWorkspace.shared.open(update.url) }
        }
    }

    // MARK: Screen

    private func preview(_ screen: ScreenSnapshot) -> some View {
        ScreenPreview(screen: screen)
            .frame(height: 150)
            .overlay(alignment: .bottomTrailing) {
                if screen.hasCustomSizes {
                    Button(String(localized: "Reset sizes")) {
                        wm.resetSizes(key: screen.key)
                        wm.record(.menuPanel)
                    }
                    .controlSize(.small).padding(6)
                }
            }
    }

    private func windowsOnThisScreen(_ screen: ScreenSnapshot) -> some View {
        let issues = wm.countIssues(for: screen)
        let maxCount = screen.display.shape == .standard ? 4 : 5
        let wanted = wm.spaces[screen.key]?.countPick ?? wm.prefs.windowsPerScreen
        return VStack(alignment: .leading, spacing: 8) {
            Text("Windows on this screen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(LayoutKind.allCases, id: \.self) { kind in
                    let disabled = screen.display.shape == .vertical && kind == .columns
                    Button {
                        wm.setLayout(kind, key: screen.key)
                        wm.record(.menuPanel)
                    } label: {
                        LayoutPicture(kind: kind, shape: screen.display.shape, count: max(3, min(4, screen.capacity)), selected: screen.kind == kind)
                            .frame(width: 34, height: screen.display.shape == .vertical ? 40 : 22)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(screen.kind == kind ? Color.accentColor.opacity(0.15) : .clear))
                    }
                    .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.3 : 1)
                    .help(WindowManager.name(of: kind))
                }
                Spacer()
                ForEach(1...maxCount, id: \.self) { n in
                    let issue = issues[n]
                    Button {
                        wm.setCount(n, key: screen.key)
                        wm.record(.menuPanel)
                    } label: {
                        Text("\(n)").font(.callout.monospacedDigit().weight(.semibold)).frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(min(wanted, screen.capacity) == n ? Color.accentColor : Color.primary.opacity(0.07)))
                            .foregroundStyle(min(wanted, screen.capacity) == n ? .white : .primary)
                    }
                    .buttonStyle(.plain).disabled(issue != nil).opacity(issue != nil ? 0.35 : 1)
                    .help(issue ?? (n == 1 ? String(localized: "1 window") : String(localized: "Up to \(n) windows")))
                }
            }
            if let reason = issues.filter({ $0.key <= maxCount && $0.key > screen.capacity }).sorted(by: { $0.key < $1.key }).first?.value {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Switches

    private var switches: some View {
        HStack(spacing: 8) {
            Button {
                wm.retile()
                wm.record(.menuPanel)
            } label: { Label(String(localized: "Retile"), systemImage: "arrow.triangle.2.circlepath") }
            Spacer()
            Toggle(String(localized: "Borders"), isOn: Binding(
                get: { wm.prefs.highlight == .borderActive || wm.prefs.highlight == .borderAll },
                set: { wm.prefs.highlight = $0 ? .borderActive : .none }
            )).toggleStyle(.button)
            Toggle(String(localized: "Hover focus"), isOn: $wm.prefs.hoverFocus).toggleStyle(.button)
                .onChange(of: wm.prefs.hoverFocus) { MouseController.shared.updateHoverFocus() }
        }
        .controlSize(.small)
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelRow(symbol: "eye.slash", title: String(localized: "No peek mode")) {
                Toggle("", isOn: $wm.prefs.noPeek).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if wm.prefs.noPeek {
                Slider(value: $wm.prefs.dimAmount, in: Preferences.dimRange) { Text("Dim") }
                    .controlSize(.small).padding(.leading, 28)
            }
            PanelRow(symbol: "rectangle.inset.filled", title: String(localized: "Clean Space")) {
                Toggle("", isOn: Binding(get: { wm.cleanSpaceKey != nil }, set: { wm.setCleanSpace($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }

    // MARK: Setups

    private var setups: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(String(localized: "Setups"), systemImage: "square.stack.3d.up")
                Text("Beta").font(.caption2.bold()).padding(.horizontal, 4).background(Color.primary.opacity(0.08), in: Capsule())
                if setupRunner.canOfferSave { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                Spacer()
                Button(String(localized: "Manage")) { Windows.shared.showSettings(page: .setups) }.buttonStyle(.link).font(.caption)
            }
            ForEach(wm.setups) { setup in
                Button {
                    SetupRunner.shared.open(setup.id)
                } label: {
                    HStack {
                        Text(setup.name)
                        Spacer()
                        if wm.activeSetupID == setup.id {
                            Text(setupRunner.isOnScreen(setup) ? String(localized: "ON SCREEN") : String(localized: "CHANGED"))
                                .font(.caption2.bold()).foregroundStyle(setupRunner.isOnScreen(setup) ? .green : .orange)
                        }
                        if let k = setup.shortcut { KeyCaps(text: k.label) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if naming {
                HStack {
                    TextField(String(localized: "Name, like “Coding”"), text: $setupName).textFieldStyle(.roundedBorder)
                        .onSubmit(saveSetup)
                    Button(String(localized: "Save"), action: saveSetup).disabled(setupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            } else if setupRunner.canOfferSave || wm.setups.isEmpty {
                Button(String(localized: "Save this arrangement as a setup…")) { naming = true }.buttonStyle(.link).font(.callout)
            }
        }
    }

    private func saveSetup() {
        let name = setupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        SetupRunner.shared.save(name: name)
        setupName = ""
        naming = false
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { Windows.shared.showSettings() } label: {
                HStack { Text("Settings…"); Spacer(); KeyCaps(text: "⌘,") }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
            Button { Windows.shared.showSettings(page: .keyboard) } label: {
                HStack {
                    Text("Keyboard shortcuts")
                    Spacer()
                    if !wm.prefs.shortcutsEnabled {
                        Text("Off").font(.caption).foregroundStyle(.secondary)
                    } else if !hotkeys.unavailable.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help(String(localized: "Another app is using some of Panefold's shortcuts"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { NSApp.terminate(nil) } label: {
                HStack { Text("Quit Panefold"); Spacer(); KeyCaps(text: "⌘Q") }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut("q")
        }
    }
}
