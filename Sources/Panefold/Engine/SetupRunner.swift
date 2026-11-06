import AppKit
import SwiftUI
import PanefoldCore

/// Saves and opens setups: named arrangements of apps across screens.
@MainActor
final class SetupRunner: ObservableObject {
    static let shared = SetupRunner()

    @Published private(set) var opening: Setup?
    @Published private(set) var secondsLeft = 0
    private var curtains: [OverlayPanel] = []
    private var timer: Timer?
    private var startedAt = Date()
    private var wm: WindowManager { .shared }

    // MARK: Saving

    /// The current arrangement: which app shows in which tile on every screen.
    func capture(name: String, id: UUID = UUID(), shortcut: KeyCombo? = nil) -> Setup {
        let screens: [SetupScreen] = wm.screens.compactMap { s in
            let tiles = s.tiles.map { t in t.windows.compactMap { wm.tracked[$0]?.bundleID } }.filter { !$0.isEmpty }
            guard !tiles.isEmpty else { return nil }
            let space = wm.spaces[s.key]
            return SetupScreen(screenID: s.display.id, screenName: s.display.name, layout: s.kind, capacity: s.capacity,
                               tiles: tiles, sizes: space?.overrides(kind: s.kind, count: tiles.count) ?? [:])
        }
        return Setup(id: id, name: name, shortcut: shortcut, screens: screens)
    }

    func save(name: String) {
        let setup = capture(name: name)
        guard !setup.screens.isEmpty else {
            Notices.shared.show(String(localized: "Nothing is tiled yet"), on: nil)
            return
        }
        wm.setups.append(setup)
        wm.activeSetupID = setup.id
        SystemState.haptic()
    }

    func update(_ id: UUID) {
        guard let i = wm.setups.firstIndex(where: { $0.id == id }) else { return }
        let old = wm.setups[i]
        wm.setups[i] = capture(name: old.name, id: old.id, shortcut: old.shortcut)
        wm.activeSetupID = id
    }

    /// Two or more apps tiled that aren't a setup yet.
    var canOfferSave: Bool {
        let current = currentArrangement
        let tiledApps = Set(current.values.flatMap { $0.compactMap(\.first) })
        guard tiledApps.count >= 2 else { return false }
        return !wm.setups.contains { SetupPlanner.matches($0, current: current) }
    }

    var currentArrangement: [String: [[String]]] {
        Dictionary(wm.screens.map { s in
            (s.display.id, s.tiles.map { t in t.windows.compactMap { wm.tracked[$0]?.bundleID } })
        }, uniquingKeysWith: { a, _ in a })
    }

    func isOnScreen(_ setup: Setup) -> Bool { SetupPlanner.matches(setup, current: currentArrangement) }

    // MARK: Opening

    func open(_ id: UUID) {
        guard opening == nil, wm.isActive, let setup = wm.setups.first(where: { $0.id == id }) else { return }
        opening = setup
        wm.activeSetupID = id
        startedAt = Date()
        showCurtains(setup)
        Log.info("Opening a setup with \(setup.apps.count) apps")

        let wanted = Set(setup.apps)
        // Other apps are hidden, never quit.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard let bid = app.bundleIdentifier else { continue }
            if wanted.contains(bid) {
                if app.isHidden { app.unhide() }
            } else {
                app.hide()
            }
        }
        for bid in setup.apps where NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        // Set each screen's layout and count to the setup's.
        let displays = Display.all()
        let main = displays.first { $0.isMain }?.id ?? displays.first?.id ?? ""
        let map = SetupPlanner.mapScreens(setup, connected: displays.map(\.id), main: main)
        for s in setup.screens {
            guard let target = map[s.screenID], let d = displays.first(where: { $0.id == target }) else { continue }
            let key = Spaces.key(for: d)
            wm.updateSpace(key, create: true) {
                $0.layoutPick = s.layout
                $0.countPick = s.capacity
                $0.sizes = [:]
                $0.setOverrides(s.sizes, kind: s.layout, count: s.tiles.count)
                $0.zoomed = nil
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(setup, map: map) }
        }
    }

    private func tick(_ setup: Setup, map: [String: String]) {
        let elapsed = Date().timeIntervalSince(startedAt)
        secondsLeft = max(0, 20 - Int(elapsed))
        wm.reconcile()
        let windows = wm.tracked.values.map { ($0.id, $0.bundleID) }
        let present = Set(windows.map(\.1))
        let displays = Display.all()
        for s in setup.screens {
            guard let target = map[s.screenID], let d = displays.first(where: { $0.id == target }) else { continue }
            let key = Spaces.key(for: d)
            let mine = windows.filter { s.apps.contains($0.1) }
            let tiles = SetupPlanner.assign(s, windows: mine)
            let placed = Set(tiles.flatMap { $0 })
            for other in wm.spaces.keys where other != key {
                wm.updateSpace(other) { space in placed.forEach { space.tiles.remove($0) } }
            }
            wm.updateSpace(key, create: true) { space in
                let rest = space.tiles.allTiled.filter { !placed.contains($0) }
                space.tiles.tiles = tiles.map { Tile($0) }
                for w in rest { space.tiles.insert(w, active: nil) }
            }
        }
        wm.reconcile(force: true)
        let missing = setup.apps.filter { !present.contains($0) }
        // Some apps ask something first (a project picker): let the user see it.
        let asking = NSWorkspace.shared.frontmostApplication.map { app in
            setup.apps.contains(app.bundleIdentifier ?? "") && AX.app(app.processIdentifier).focusedWindow?.subrole == kAXDialogSubrole
        } ?? false
        if missing.isEmpty || elapsed > 20 || asking {
            finish(missing: missing)
        }
    }

    func finish(missing: [String] = []) {
        timer?.invalidate()
        timer = nil
        curtains.forEach { $0.orderOut(nil) }
        curtains.removeAll()
        HotkeyBinder.shared.setEscape(nil)
        if !missing.isEmpty {
            let names = missing.map { id in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id }
            Notices.shared.show(String(localized: "Still waiting for \(names.joined(separator: ", "))"), on: nil)
        } else {
            NSSound(named: "Glass")?.play()
        }
        opening = nil
        // Late windows still go to their tiles for a while.
        if let setup = wm.setups.first(where: { $0.id == wm.activeSetupID }), !missing.isEmpty {
            let map = SetupPlanner.mapScreens(setup, connected: Display.all().map(\.id), main: Display.all().first?.id ?? "")
            var tries = 0
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    tries += 1
                    if tries > 90 { t.invalidate() }
                    let present = Set(WindowManager.shared.tracked.values.map(\.bundleID))
                    if missing.allSatisfy(present.contains) {
                        self?.tick(setup, map: map)
                        t.invalidate()
                    }
                }
            }
        }
    }

    /// The screens blur while apps open; the menu bar and Dock stay usable.
    private func showCurtains(_ setup: Setup) {
        HotkeyBinder.shared.setEscape { [weak self] in self?.lift() }
        for d in Display.all() {
            let p = OverlayPanel(clickThrough: false, level: .floating)
            p.host(Curtain(runner: self, name: setup.name))
            p.place(d.visible)
            p.orderFront(nil)
            curtains.append(p)
        }
    }

    /// Show My Screen: the blur goes, apps keep landing in their tiles.
    func lift() {
        curtains.forEach { $0.orderOut(nil) }
        curtains.removeAll()
        HotkeyBinder.shared.setEscape(nil)
    }
}

private struct Curtain: View {
    @ObservedObject var runner: SetupRunner
    let name: String

    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI)
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Opening \(name)…").font(.title2.weight(.semibold))
                Text("\(runner.secondsLeft) s").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button("Show My Screen") { runner.lift() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
