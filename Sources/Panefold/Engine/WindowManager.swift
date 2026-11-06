import AppKit
import Combine
import PanefoldCore

/// A window Panefold knows about. Titles are never kept here.
struct TrackedWindow {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    var frame: CGRect
}

enum TilingStatus: Equatable {
    case tiling(Int)
    case focusMode(Int)
    case pausedForStageManager
    case waitingForSetup
    case off
    case needsAccess

    var isWorking: Bool {
        switch self {
        case .tiling, .focusMode: true
        default: false
        }
    }
}

/// What one screen looks like right now, for the menu bar panel and the overlays.
struct ScreenSnapshot: Identifiable {
    let display: Display
    let key: String
    let kind: LayoutKind
    let capacity: Int
    let tiles: [Tile]
    let tileFrames: [CGRect]
    let zoomed: WindowID?
    let hasCustomSizes: Bool
    let pickedLayout: Bool
    var id: String { key }
}

@MainActor
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published var prefs: Preferences {
        didSet { if prefs != oldValue { preferencesChanged(from: oldValue) } }
    }
    @Published private(set) var status: TilingStatus = .off
    @Published private(set) var trusted = AX.isTrusted()
    @Published private(set) var activeWindow: WindowID?
    @Published private(set) var screens: [ScreenSnapshot] = []
    @Published private(set) var cleanSpaceKey: String?
    @Published private(set) var secureInput = false
    /// The app in front, other than Panefold: what "Tile <app>" in the panel refers to.
    @Published private(set) var frontApp: NSRunningApplication?
    @Published var setups: [Setup] { didSet { Store.save(setups, key: "setups"); HotkeyBinder.shared.rebind() } }
    @Published var activeSetupID: UUID?
    @Published var activity: ActivityLog
    @Published var learner: MinSizeLearner { didSet { Store.save(learner, key: "minSizes") } }

    private(set) var tracked: [WindowID: TrackedWindow] = [:]
    private(set) var spaces: [String: ScreenSpace]
    private(set) var plans: [String: Plan] = [:]
    private(set) var displays: [Display] = []
    private(set) var currentKeys: [String: Display] = [:]
    private(set) var mru: [WindowID] = []
    private var watchers: [pid_t: AppWatcher] = [:]
    private var manualFloat: Set<WindowID> = []
    private var unfitFloat: Set<WindowID> = []
    private var centeredOverflow: Set<WindowID> = []
    private var cleanWindows: [WindowID] = []
    private var expected: [WindowID: (frame: CGRect, at: Date)] = [:]
    private var lastRoomCard: [String: Date] = [:]
    private let reconcileSoon = Debouncer(0.04)
    private let reconcileLater = Debouncer(0.2)
    private let saveSoon = Debouncer(1.0)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Set while the user drags with the mouse: windows aren't put back mid-drag.
    var mouseIsDown = false

    var isActive: Bool {
        prefs.tilingEnabled && trusted && prefs.onboardingDone && !SystemState.stageManagerOn
    }

    private init() {
        prefs = Store.load(Preferences.self, key: "preferences") ?? Preferences()
        spaces = Store.load([String: ScreenSpace].self, key: "spaces") ?? [:]
        setups = Store.load([Setup].self, key: "setups") ?? []
        activity = Store.load(ActivityLog.self, key: "activity") ?? ActivityLog()
        learner = Store.load(MinSizeLearner.self, key: "minSizes") ?? MinSizeLearner()
        manualFloat = Set(Store.load([WindowID].self, key: "floating") ?? [])
    }

    // MARK: - Lifecycle

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didTerminateApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        self?.watchers[app.processIdentifier] = nil
                    }
                    self?.scheduleReconcile()
                }
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshActive() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleReconcile()
                self?.scheduleReconcile(later: true)
            }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setCleanSpace(false) }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setCleanSpace(false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let key = self.cleanSpaceKey, !Display.all().contains(where: { Spaces.displayID(fromKey: key) == $0.id }) {
                    self.setCleanSpace(false)
                }
                self.scheduleReconcile(later: true)
            }
        })
        // Permission, Stage Manager and Secure Input have no notifications worth trusting; a slow poll is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.5
        HotkeyBinder.shared.rebind()
        applyAppearance()
        reconcile()
        refreshActive()
    }

    private var lastStageManager = SystemState.stageManagerOn

    private func poll() {
        if mouseIsDown, NSEvent.pressedMouseButtons == 0 {
            mouseIsDown = false
            scheduleReconcile()
        }
        let nowTrusted = AX.isTrusted()
        if nowTrusted != trusted {
            trusted = nowTrusted
            if trusted { SystemState.haptic() }
            HotkeyBinder.shared.rebind()
            reconcile()
        }
        let stage = SystemState.stageManagerOn
        if stage != lastStageManager {
            lastStageManager = stage
            reconcile()
        }
        let secure = SystemState.secureInputOn
        if secure != secureInput { secureInput = secure }
        updateStatus()
    }

    func scheduleReconcile(later: Bool = false) {
        (later ? reconcileLater : reconcileSoon).call { [weak self] in self?.reconcile() }
    }

    private func preferencesChanged(from old: Preferences) {
        Store.save(prefs, key: "preferences")
        if old.shortcuts != prefs.shortcuts || old.shortcutsEnabled != prefs.shortcutsEnabled || old.tilingEnabled != prefs.tilingEnabled
            || old.onboardingDone != prefs.onboardingDone {
            HotkeyBinder.shared.rebind()
        }
        if old.appearance != prefs.appearance { applyAppearance() }
        if old.iconStyle != prefs.iconStyle { AppIcon.apply(prefs.iconStyle) }
        if old.openAtLogin != prefs.openAtLogin { SystemState.setOpenAtLogin(prefs.openAtLogin) }
        if old.whenFull != prefs.whenFull {
            for key in spaces.keys { updateSpace(key) { $0.tiles.setCapacity($0.tiles.capacity, whenFull: prefs.whenFull) } }
        }
        if old.layout != prefs.layout || old.windowsPerScreen != prefs.windowsPerScreen {
            for key in spaces.keys { spaces[key]?.zoomed = nil }
        }
        if old.exclusions != prefs.exclusions || old.floatRules != prefs.floatRules { unfitFloat.removeAll() }
        reconcile()
    }

    func applyAppearance() {
        switch prefs.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Accessibility events

    private func ensureWatcher(_ pid: pid_t) -> AppWatcher? {
        if let w = watchers[pid] { return w }
        let w = AppWatcher(pid: pid) { [weak self] name, element in
            MainActor.assumeIsolated { self?.axEvent(name, element) }
        }
        watchers[pid] = w
        return w
    }

    private func axEvent(_ name: String, _ element: AXUIElement) {
        switch name {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            refreshActive()
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard !mouseIsDown, let id = element.windowID else { return }
            if let e = expected[id], Date().timeIntervalSince(e.at) < 0.6 { return }
            if tracked[id] != nil { scheduleReconcile(later: true) }
        case kAXTitleChangedNotification:
            if !prefs.floatRules.isEmpty { scheduleReconcile(later: true) }
        case kAXUIElementDestroyedNotification:
            scheduleReconcile()
        default:
            scheduleReconcile()
        }
    }

    // MARK: - Reconcile

    /// Brings every screen's layout in line with the windows that exist, then puts each window in its place.
    func reconcile(force: Bool = false) {
        displays = Display.all()
        currentKeys = Dictionary(displays.map { (Spaces.key(for: $0), $0) }, uniquingKeysWith: { a, _ in a })
        defer {
            updateStatus()
            publishScreens()
            Overlays.shared.update()
            saveSoon.call { [weak self] in self?.persist() }
        }
        guard isActive else {
            plans.removeAll()
            return
        }
        let server = WindowServer.onScreen()
        let onScreen = Dictionary(server.filter { $0.layer == 0 }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let zIndex = Dictionary(server.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let own = ProcessInfo.processInfo.processIdentifier

        var candidates: [WindowID: TrackedWindow] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != own && !app.isHidden {
            guard let bundleID = app.bundleIdentifier, let watcher = ensureWatcher(app.processIdentifier) else { continue }
            let excluded = prefs.exclusions.isExcluded(bundleID)
            for w in watcher.element.windows {
                guard let id = w.windowID, let s = onScreen[id] else { continue }
                watcher.watch(w, id: id)
                guard !excluded, w.subrole == kAXStandardWindowSubrole, !w.isFullScreen, !w.isMinimized, w.isSizeSettable else { continue }
                if !prefs.floatRules.isEmpty, prefs.isFloatedByRule(bundleID: bundleID, title: w.title ?? "") { continue }
                candidates[id] = TrackedWindow(id: id, element: w, pid: app.processIdentifier, bundleID: bundleID,
                                               appName: app.localizedName ?? bundleID, frame: w.frame ?? s.bounds)
            }
        }
        tracked = candidates
        attempts = attempts.filter { candidates[$0.key] != nil }
        manualFloat.formIntersection(candidates.keys)
        unfitFloat.formIntersection(candidates.keys)

        var displayOf: [WindowID: Display] = [:]
        for (id, t) in candidates { displayOf[id] = Display.containing(t.frame, in: displays) }

        // Drop windows that closed, hid, or (outside a drag) moved to another screen.
        for (key, display) in currentKeys {
            var space = spaces[key] ?? ScreenSpace(capacity: prefs.windowsPerScreen)
            let before = space.tiles.allTiled.count + space.tiles.overflow.count
            for w in space.tiles.allTiled + space.tiles.overflow {
                let gone = candidates[w] == nil || manualFloat.contains(w) || unfitFloat.contains(w)
                let moved = !mouseIsDown && displayOf[w].map { $0.id != display.id } == true
                if gone || moved { space.tiles.remove(w) }
            }
            if space.tiles.allTiled.count + space.tiles.overflow.count < before {
                // Room opened up: windows that didn't fit get another chance.
                for w in unfitFloat where displayOf[w]?.id == display.id { unfitFloat.remove(w) }
            }
            if let z = space.zoomed, !space.tiles.contains(z) { space.zoomed = nil }
            spaces[key] = space
        }
        cleanWindows.removeAll { candidates[$0] == nil }

        // New windows take a place on the screen they opened on, frontmost first.
        let placed = Set(currentKeys.keys.flatMap { spaces[$0].map { $0.tiles.allTiled + $0.tiles.overflow } ?? [] })
        let fresh = candidates.keys.filter { !placed.contains($0) && !manualFloat.contains($0) && !unfitFloat.contains($0) }
            .sorted { (zIndex[$0] ?? .max) < (zIndex[$1] ?? .max) }
        for w in fresh {
            guard let display = displayOf[w], let key = currentKeys.first(where: { $0.value.id == display.id })?.key else { continue }
            for other in spaces.keys where other != key { spaces[other]?.tiles.remove(w) }
            var space = spaces[key]!
            syncCapacity(&space, display: display)
            let active = activeWindow.flatMap { space.tiles.contains($0) ? $0 : nil }
            let outcome = space.tiles.insert(w, active: active, placement: prefs.newWindows, whenFull: prefs.whenFull)
            space.zoomed = nil
            if case .stacked = outcome, !Store.bool("stackNoticeShown") {
                Store.set(true, forKey: "stackNoticeShown")
                Notices.shared.show(String(localized: "Screen full: the new window joined your tile. ⌃⌥` shows the one behind it."), on: display)
            }
            if case .overflowed = outcome { Notices.shared.show(String(localized: "This Space is full"), on: display) }
            if cleanSpaceKey == key { cleanWindows.append(w) }
            spaces[key] = space
            record(.placed)
        }

        plans.removeAll()
        for (key, display) in currentKeys {
            guard var space = spaces[key] else { continue }
            syncCapacity(&space, display: display)
            spaces[key] = space
            layoutScreen(key: key, display: display, force: force)
        }
        // Floating windows waiting for room go to the middle, once.
        for key in currentKeys.keys {
            for w in spaces[key]?.tiles.overflow ?? [] where !centeredOverflow.contains(w) {
                centeredOverflow.insert(w)
                if let t = tracked[w], let d = currentKeys[key] {
                    place(t, Planner.centered(in: d.geometry(insets: prefs.insets(for: d.id)).area, size: t.frame.size))
                }
            }
        }
        centeredOverflow.formIntersection(Set(currentKeys.keys.flatMap { spaces[$0]?.tiles.overflow ?? [] }))
    }

    private func syncCapacity(_ space: inout ScreenSpace, display: Display) {
        let (_, capacity) = Planner.shape(of: space, prefs: prefs, geometry: display.geometry(insets: prefs.insets(for: display.id)))
        if space.tiles.capacity != capacity { space.tiles.setCapacity(capacity, whenFull: prefs.whenFull) }
    }

    @discardableResult
    private func layoutScreen(key: String, display: Display, force: Bool) -> Int {
        guard var space = spaces[key] else { return 0 }
        let geometry = display.geometry(insets: prefs.insets(for: display.id))
        let minSize: (WindowID) -> CGSize? = { [tracked, learner] w in tracked[w].flatMap { learner.minimum(for: $0.bundleID) } }

        if cleanSpaceKey == key {
            var clean = ScreenSpace(capacity: max(1, min(4, cleanWindows.count)))
            for w in cleanWindows { clean.tiles.insert(w, active: nil) }
            let plan = Planner.plan(clean, prefs: prefs, geometry: geometry, minSize: minSize)
            plans[key] = plan
            return apply(plan, force: force)
        }

        var plan = Planner.plan(space, prefs: prefs, geometry: geometry, minSize: minSize)
        var rounds = 0
        while !plan.unfit.isEmpty, rounds < 4 {
            rounds += 1
            for w in plan.unfit {
                space.tiles.remove(w)
                unfitFloat.insert(w)
                if let t = tracked[w] {
                    place(t, Planner.centered(in: geometry.area, size: learner.minimum(for: t.bundleID)))
                    offerRoom(for: t, display: display, space: space)
                }
            }
            plan = Planner.plan(space, prefs: prefs, geometry: geometry, minSize: minSize)
        }
        spaces[key] = space
        plans[key] = plan
        return apply(plan, force: force)
    }

    /// Moves windows that aren't where the plan says. Returns how many moved.
    @discardableResult
    private func apply(_ plan: Plan, force: Bool) -> Int {
        var moved = 0
        for (w, frame) in plan.frames {
            guard let t = tracked[w] else { continue }
            if !force, Self.same(t.frame, frame) { continue }
            if place(t, frame) { moved += 1 }
        }
        return moved
    }

    /// How often each window was put at the same frame recently, so Panefold stops fighting an app
    /// that keeps putting its window back.
    private var attempts: [WindowID: (frame: CGRect, count: Int, since: Date)] = [:]

    @discardableResult
    private func place(_ t: TrackedWindow, _ frame: CGRect) -> Bool {
        if Self.same(t.frame, frame) { return false }
        if let a = attempts[t.id], Self.same(a.frame, frame), Date().timeIntervalSince(a.since) < 10 {
            if a.count >= 4 { return false }
            attempts[t.id] = (frame, a.count + 1, a.since)
        } else {
            attempts[t.id] = (frame, 1, Date())
        }
        expected[t.id] = (frame, Date())
        t.element.setFrame(frame)
        tracked[t.id]?.frame = frame
        // Check a moment later whether the app accepted the size; that's how minimum sizes are learned.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let actual = t.element.frame else { return }
            self.tracked[t.id]?.frame = actual
            let screen = Display.containing(frame, in: self.displays)?.visible.size ?? frame.size
            if self.learner.observe(bundleID: t.bundleID, requested: frame.size, actual: actual.size, screen: screen) {
                Log.info("Learned a minimum size for an app")
                self.reconcile()
            } else if actual.width > frame.width + MinSizeLearner.slack || actual.height > frame.height + MinSizeLearner.slack {
                // Ask once more: the second refusal teaches us its limit.
                self.scheduleReconcile(later: true)
            }
        }
        return true
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5 && abs(a.width - b.width) < 1.5 && abs(a.height - b.height) < 1.5
    }

    private func persist() {
        // Only Spaces seen in the last session matter; old ones are dropped after a while by size.
        if spaces.count > 64 {
            let keep = Set(currentKeys.keys)
            spaces = spaces.filter { keep.contains($0.key) || !$0.value.tiles.isEmpty }
        }
        Store.save(spaces, key: "spaces")
        Store.save(Array(manualFloat), key: "floating")
        Store.save(activity, key: "activity")
    }

    // MARK: - State for the interface

    private func updateStatus() {
        let new: TilingStatus
        if !trusted {
            new = .needsAccess
        } else if !prefs.onboardingDone {
            new = .waitingForSetup
        } else if !prefs.tilingEnabled {
            new = .off
        } else if SystemState.stageManagerOn {
            new = .pausedForStageManager
        } else {
            let count = currentKeys.keys.compactMap { spaces[$0]?.tiles.allTiled.count }.reduce(0, +)
            let zoomed = currentKeys.keys.contains { spaces[$0]?.zoomed != nil }
            new = zoomed ? .focusMode(count) : .tiling(count)
        }
        if new != status { status = new }
        MenuBarIcon.shared.update(filled: new.isWorking, cleanSpace: cleanSpaceKey != nil)
    }

    private func publishScreens() {
        screens = currentKeys.map { key, display in
            let space = spaces[key] ?? ScreenSpace(capacity: prefs.windowsPerScreen)
            let shape = Planner.shape(of: space, prefs: prefs, geometry: display.geometry(insets: prefs.insets(for: display.id)))
            return ScreenSnapshot(display: display, key: key, kind: shape.kind, capacity: shape.capacity,
                                  tiles: space.tiles.tiles, tileFrames: plans[key]?.tileFrames ?? [],
                                  zoomed: space.zoomed, hasCustomSizes: space.hasCustomSizes, pickedLayout: space.layoutPick != nil)
        }.sorted { $0.display.frame.minX < $1.display.frame.minX }
    }

    /// The screen the pointer is on.
    var pointerScreen: ScreenSnapshot? {
        let p = Display.mouse
        return screens.first { $0.display.frame.contains(p) } ?? screens.first
    }

    func appIcon(_ w: WindowID) -> NSImage? {
        tracked[w].flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon }
    }

    func appName(_ w: WindowID) -> String? { tracked[w]?.appName }

    func isTiled(_ w: WindowID) -> Bool { locate(w) != nil }
    func isFloating(_ w: WindowID) -> Bool { manualFloat.contains(w) }

    /// Why each count doesn't fit this screen, if it doesn't.
    func countIssues(for snapshot: ScreenSnapshot) -> [Int: String] {
        let geometry = snapshot.display.geometry(insets: prefs.insets(for: snapshot.display.id))
        var mins: [Int: CGSize] = [:]
        var names: [Int: String] = [:]
        for (i, t) in snapshot.tiles.enumerated() {
            if let w = tracked[t.showing], let m = learner.minimum(for: w.bundleID) {
                mins[i] = m
                names[i] = w.appName
            }
        }
        var out: [Int: String] = [:]
        for n in 1...5 {
            guard let issue = Capacity.issue(count: n, kind: snapshot.kind, shape: snapshot.display.shape, area: geometry.area,
                                             gap: prefs.effectiveGap, mainSize: prefs.mainSize, minSizes: mins) else { continue }
            switch issue {
            case .screenTooSmall:
                out[n] = n > LayoutBuilder.hardLimit(snapshot.kind, shape: snapshot.display.shape)
                    ? String(localized: "This layout holds at most \(LayoutBuilder.hardLimit(snapshot.kind, shape: snapshot.display.shape)) here")
                    : String(localized: "The screen is too small for \(n) windows in this layout")
            case .appNeedsRoom(let tile):
                out[n] = String(localized: "\(names[tile] ?? String(localized: "An app")) needs more room than \(n) windows leave")
            }
        }
        return out
    }

    // MARK: - Finding things

    func locate(_ w: WindowID) -> (key: String, display: Display)? {
        for (key, display) in currentKeys where spaces[key]?.tiles.contains(w) == true && spaces[key]?.tiles.overflow.contains(w) == false {
            return (key, display)
        }
        return nil
    }

    private func targetScreen() -> (key: String, display: Display)? {
        if let a = activeWindow, let found = locate(a) { return found }
        if let a = activeWindow, let t = tracked[a], let d = Display.containing(t.frame, in: displays),
           let key = currentKeys.first(where: { $0.value.id == d.id })?.key { return (key, d) }
        guard let s = pointerScreen else { return nil }
        return (s.key, s.display)
    }

    // MARK: - Active window

    func refreshActive() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular, frontApp != app { frontApp = app }
        let id = AX.app(app.processIdentifier).focusedWindow?.windowID
        guard id != activeWindow || id == nil else { return }
        activeWindow = id
        defer { Overlays.shared.update() }
        guard let id else { return }
        if isActive, tracked[id] == nil { scheduleReconcile(later: true) }
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > 200 { mru.removeLast() }
        guard isActive, let (key, display) = locate(id) else {
            if isActive, let clean = cleanSpaceKey, let t = tracked[id], Display.containing(t.frame, in: displays)?.id == currentKeys[clean]?.id,
               !cleanWindows.contains(id) {
                cleanWindows.append(id)
                reconcile()
            }
            return
        }
        var space = spaces[key]!
        var changed = space.tiles.bringToFront(id)
        // Switching to another tiled window on that screen ends focus mode.
        if let z = space.zoomed, z != id {
            space.zoomed = nil
            changed = true
        }
        spaces[key] = space
        if cleanSpaceKey == key, !cleanWindows.contains(id) {
            cleanWindows.append(id)
            changed = true
        }
        if changed {
            layoutScreen(key: key, display: display, force: false)
            publishScreens()
        }
    }

    func activate(_ w: WindowID) {
        guard let t = tracked[w] ?? TabViewController.element(for: w) else { return }
        if t.element.isMinimized { t.element.setMinimized(false) }
        NSRunningApplication(processIdentifier: t.pid)?.activate()
        t.element.raise()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.refreshActive() }
    }

    // MARK: - Commands

    func record(_ kind: ActivityKind, detail: String? = nil) {
        guard prefs.countActivity else { return }
        activity.record(kind, detail: detail)
    }

    func updateSpace(_ key: String, create: Bool = false, _ body: (inout ScreenSpace) -> Void) {
        guard var s = spaces[key] ?? (create ? ScreenSpace(capacity: prefs.windowsPerScreen) : nil) else { return }
        body(&s)
        spaces[key] = s
    }

    func swap(_ direction: Direction) {
        guard isActive, let a = activeWindow, let (key, display) = locate(a), let plan = plans[key], let from = plan.frames[a] else { return }
        let space = spaces[key]!
        let others = space.tiles.showing.filter { $0 != a }.compactMap { w in plan.frames[w].map { (w, $0) } }
        if let b = Navigator.neighbor(of: from, in: others, direction: direction) {
            updateSpace(key) {
                $0.tiles.swap(a, b)
                $0.zoomed = nil
            }
            layoutScreen(key: key, display: display, force: false)
            publishScreens()
            Overlays.shared.update()
            return
        }
        // Nothing that way on this screen: go to the next screen in that direction.
        let neighbors = currentKeys.filter { $0.value.id != display.id }.map { ($0.key, $0.value.frame) }
        guard let targetKey = Navigator.neighbor(of: display.frame, in: neighbors, direction: direction, tolerance: 2) else { return }
        moveWindow(a, toScreen: targetKey, landingNear: from, direction: direction)
    }

    /// Moves a tiled window into another screen's layout. A full screen swaps (or stacks); one with room
    /// takes it as its newest window, if its app fits there.
    func moveWindow(_ a: WindowID, toScreen targetKey: String, landingNear from: CGRect? = nil, direction: Direction? = nil) {
        guard let (key, display) = locate(a), let target = currentKeys[targetKey], var dest = spaces[targetKey] else { return }
        let geometry = target.geometry(insets: prefs.insets(for: target.id))
        syncCapacity(&dest, display: target)
        if dest.tiles.tiles.count < dest.tiles.capacity {
            var mins: [Int: CGSize] = [:]
            for (i, t) in dest.tiles.tiles.enumerated() { if let m = tracked[t.showing].flatMap({ learner.minimum(for: $0.bundleID) }) { mins[i] = m } }
            if let m = tracked[a].flatMap({ learner.minimum(for: $0.bundleID) }) { mins[dest.tiles.tiles.count] = m }
            if case .appNeedsRoom = Capacity.issue(count: dest.tiles.tiles.count + 1, kind: Planner.shape(of: dest, prefs: prefs, geometry: geometry).kind,
                                                   shape: target.shape, area: geometry.area, gap: prefs.effectiveGap, mainSize: prefs.mainSize, minSizes: mins) {
                Notices.shared.show(String(localized: "\(tracked[a]?.appName ?? "This app") needs more room than that screen has. Pick fewer windows there."), on: target)
                return
            }
            updateSpace(key) {
                $0.tiles.remove(a)
                $0.zoomed = nil
            }
            dest.tiles.insert(a, active: nil)
        } else {
            let destPlan = plans[targetKey]
            let landing = destPlan.flatMap { p -> WindowID? in
                guard let from, let direction else { return nil }
                let items = dest.tiles.showing.compactMap { w in p.frames[w].map { (w, $0) } }
                // Land on the nearest window on that screen's facing side.
                let probe: CGRect
                switch direction {
                case .right: probe = CGRect(x: target.frame.minX - from.width, y: from.minY, width: from.width, height: from.height)
                case .left: probe = CGRect(x: target.frame.maxX, y: from.minY, width: from.width, height: from.height)
                case .down: probe = CGRect(x: from.minX, y: target.frame.minY - from.height, width: from.width, height: from.height)
                case .up: probe = CGRect(x: from.minX, y: target.frame.maxY, width: from.width, height: from.height)
                }
                return Navigator.neighbor(of: probe, in: items, direction: direction, tolerance: 4000)
            } ?? dest.tiles.showing.last
            guard let b = landing, let i = spaces[key]?.tiles.tileIndex(of: a), let j = dest.tiles.tileIndex(of: b) else { return }
            switch prefs.movingIntoFull {
            case .swap:
                updateSpace(key) {
                    $0.tiles.bringToFront(a)
                    $0.tiles.tiles[i].windows[0] = b
                    $0.zoomed = nil
                }
                dest.tiles.bringToFront(b)
                dest.tiles.tiles[j].windows[0] = a
            case .stack:
                updateSpace(key) {
                    $0.tiles.remove(a)
                    $0.zoomed = nil
                }
                dest.tiles.tiles[j].windows.insert(a, at: 0)
            }
        }
        dest.zoomed = nil
        spaces[targetKey] = dest
        layoutScreen(key: key, display: display, force: false)
        layoutScreen(key: targetKey, display: target, force: false)
        publishScreens()
        Overlays.shared.update()
        activate(a)
    }

    func makePrimary() {
        guard isActive, let a = activeWindow, let (key, display) = locate(a) else { return }
        updateSpace(key) {
            $0.tiles.makePrimary(a)
            $0.zoomed = nil
        }
        layoutScreen(key: key, display: display, force: false)
        publishScreens()
        Overlays.shared.update()
    }

    func focusNeighbor(forward: Bool) {
        guard isActive, let (key, _) = targetScreen(), let order = spaces[key]?.tiles.showing, !order.isEmpty else { return }
        let index = activeWindow.flatMap { order.firstIndex(of: $0) }
        let next = index.map { (($0 + (forward ? 1 : -1)) % order.count + order.count) % order.count } ?? 0
        activate(order[next])
    }

    func cycleStack(forward: Bool, of window: WindowID? = nil) {
        guard isActive, let a = window ?? activeWindow, let (key, display) = locate(a) else { return }
        var shown: WindowID?
        updateSpace(key) { shown = $0.tiles.cycle(tileOf: a, forward: forward) }
        guard let shown else { return }
        layoutScreen(key: key, display: display, force: false)
        activate(shown)
        publishScreens()
    }

    func show(_ w: WindowID) {
        guard let (key, display) = locate(w) else { return activate(w) }
        updateSpace(key) { $0.tiles.bringToFront(w) }
        layoutScreen(key: key, display: display, force: false)
        activate(w)
        publishScreens()
    }

    func resize(grow: Bool) {
        guard isActive, let a = activeWindow, let (key, display) = locate(a), let plan = plans[key],
              let tile = spaces[key]?.tiles.tileIndex(of: a) else { return }
        let step = max(40, display.visible.width * 0.04)
        guard let updates = Resizer.weightsAfterStep(plan.result, leaf: tile, delta: grow ? step : -step) else {
            NSSound.beep()
            Notices.shared.show(grow ? String(localized: "Maximum size reached") : String(localized: "Minimum size reached"), on: display)
            return
        }
        updateSpace(key) { $0.setOverrides(updates, kind: plan.kind, count: plan.count) }
        layoutScreen(key: key, display: display, force: false)
        publishScreens()
        Overlays.shared.update()
    }

    func resetSizes(key: String? = nil) {
        guard let (k, display) = key.flatMap({ k in currentKeys[k].map { (k, $0) } }) ?? targetScreen() else { return }
        updateSpace(k) { $0.sizes.removeAll() }
        layoutScreen(key: k, display: display, force: false)
        publishScreens()
        Overlays.shared.update()
    }

    /// The user dragged the edge between tiles.
    func edgeDragged(_ w: WindowID, from old: CGRect, to new: CGRect) {
        guard let (key, display) = locate(w), let plan = plans[key], let tile = spaces[key]?.tiles.tileIndex(of: w),
              let tileFrame = plan.tileFrames[safe: tile] else { return }
        if let t = tracked[w] { learner.userResized(bundleID: t.bundleID, to: new.size) }
        let updates = Resizer.weightsAfterDrag(plan.result, leaf: tile, old: tileFrame, new: new, gap: prefs.effectiveGap)
        if !updates.isEmpty {
            updateSpace(key) { $0.setOverrides(updates, kind: plan.kind, count: plan.count) }
            record(.edgeResize)
        }
        _ = old
        layoutScreen(key: key, display: display, force: true)
        publishScreens()
        Overlays.shared.update()
    }

    func setLayout(_ kind: LayoutKind, key: String? = nil) {
        guard let (k, display) = key.flatMap({ k in currentKeys[k].map { (k, $0) } }) ?? targetScreen() else { return }
        if display.shape == .vertical, kind == .columns {
            Notices.shared.show(String(localized: "Columns would be too narrow on a vertical screen"), on: display)
            return
        }
        updateSpace(k) {
            $0.layoutPick = kind
            $0.zoomed = nil
        }
        unfitFloat.removeAll()
        Notices.shared.show(Self.name(of: kind), on: display)
        reconcile()
    }

    func setCount(_ n: Int, key: String? = nil) {
        guard let (k, display) = key.flatMap({ k in currentKeys[k].map { (k, $0) } }) ?? targetScreen() else { return }
        updateSpace(k) {
            $0.countPick = n
            $0.zoomed = nil
        }
        unfitFloat.removeAll()
        reconcile()
        let actual = spaces[k]?.tiles.capacity ?? n
        Notices.shared.show(actual < n ? String(localized: "\(actual) windows: as many as fit here") : (n == 1 ? String(localized: "1 window") : String(localized: "Up to \(n) windows")), on: display)
    }

    func toggleFloat(_ window: WindowID? = nil) {
        guard isActive, let a = window ?? activeWindow, let t = tracked[a] else { return }
        if manualFloat.remove(a) != nil {
            reconcile()
            return
        }
        guard let (key, display) = locate(a) else { return }
        updateSpace(key) { $0.tiles.remove(a) }
        manualFloat.insert(a)
        place(t, Planner.centered(in: display.geometry(insets: prefs.insets(for: display.id)).area))
        reconcile()
    }

    /// Asks to always float windows like the active one: same app, same first two words of the title.
    func alwaysFloat(_ window: WindowID? = nil) {
        guard let a = window ?? activeWindow, let t = tracked[a] ?? TabViewController.element(for: a) else { return }
        let display = Display.containing(t.frame, in: displays)
        guard let prefix = FloatRule.prefix(forTitle: t.element.title ?? "") else {
            Notices.shared.show(String(localized: "This window has no title. Float it with ⌃⌥F instead."), on: display)
            return
        }
        let rule = FloatRule(bundleID: t.bundleID, appName: t.appName, prefix: prefix)
        if prefs.floatRules.contains(rule) {
            Notices.shared.show(String(localized: "Already floats every time"), on: display)
            return
        }
        NSSound(named: "Pop")?.play()
        ConfirmCard.shared.ask(
            String(localized: "Always float “\(prefix)” windows?"),
            detail: String(localized: "\(t.appName) windows whose title starts with these words will float. Other windows keep tiling."),
            confirm: String(localized: "Always Float"), near: t.frame
        ) { [weak self] in
            self?.prefs.floatRules.append(rule)
        }
    }

    func toggleFocusMode() {
        guard isActive, let a = activeWindow, let (key, display) = locate(a) else { return }
        updateSpace(key) { $0.zoomed = $0.zoomed == a ? nil : a }
        layoutScreen(key: key, display: display, force: false)
        tracked[a]?.element.raise()
        updateStatus()
        publishScreens()
        Overlays.shared.update()
    }

    func toggleNoPeek() { prefs.noPeek.toggle() }

    func setCleanSpace(_ on: Bool) {
        if !on {
            guard cleanSpaceKey != nil else { return }
            cleanSpaceKey = nil
            cleanWindows.removeAll()
            reconcile()
            return
        }
        guard isActive, let (key, _) = targetScreen() else { return }
        cleanSpaceKey = key
        cleanWindows = activeWindow.flatMap { w in tracked[w].map { _ in [w] } } ?? []
        reconcile()
    }

    func toggleCleanSpace() { setCleanSpace(cleanSpaceKey == nil) }

    func retile() {
        guard isActive else { return }
        attempts.removeAll()
        var moved = 0
        reconcile()
        for (key, display) in currentKeys { moved += layoutScreen(key: key, display: display, force: false) }
        Notices.shared.show(moved == 0 ? String(localized: "Everything was already in place") : String(localized: "Put \(moved) windows back in place"), on: targetScreen()?.display)
    }

    func toggleTiling() {
        prefs.tilingEnabled.toggle()
        Notices.shared.show(prefs.tilingEnabled ? String(localized: "Tiling on") : String(localized: "Tiling off: windows stay where they are"), on: targetScreen()?.display)
    }

    func isAppTiled(_ bundleID: String) -> Bool { !prefs.exclusions.isExcluded(bundleID) }

    func setAppTiled(_ bundleID: String, name: String, _ on: Bool) {
        if on { prefs.exclusions.include(bundleID) } else { prefs.exclusions.exclude(bundleID, name: name) }
    }

    /// Lays out every screen from scratch: used after the welcome tour.
    func tidyEverything() {
        prefs.onboardingDone = true
        reconcile(force: true)
        SystemState.haptic()
    }

    // MARK: - Mouse

    /// A window was dropped after a drag that moved it without resizing.
    func windowDropped(_ w: WindowID, at point: CGPoint, command: Bool, option: Bool) {
        guard isActive else { return }
        let target = windowUnder(point, excluding: w)
        let pointKey = currentKeys.first { $0.value.frame.contains(point) }?.key
        let fromKey = locate(w)?.key

        if command, let fromKey, let target, let toKey = locate(target)?.key {
            if option {
                updateSpace(fromKey) { $0.tiles.remove(w) }
                updateSpace(toKey) { $0.tiles.stack(w, onto: target) }
            } else if fromKey == toKey {
                updateSpace(fromKey) { $0.tiles.swap(w, target) }
            } else if let i = spaces[fromKey]?.tiles.tileIndex(of: w), let j = spaces[toKey]?.tiles.tileIndex(of: target) {
                updateSpace(fromKey) {
                    $0.tiles.bringToFront(w)
                    $0.tiles.tiles[i].windows[0] = target
                }
                updateSpace(toKey) {
                    $0.tiles.bringToFront(target)
                    $0.tiles.tiles[j].windows[0] = w
                }
            }
            updateSpace(fromKey) { $0.zoomed = nil }
            updateSpace(toKey) { $0.zoomed = nil }
            record(.commandDrag)
        } else if let fromKey, let pointKey, pointKey != fromKey {
            // Dropped on another screen: it joins as the newest window, unless that screen is full.
            if var dest = spaces[pointKey], let d = currentKeys[pointKey] {
                syncCapacity(&dest, display: d)
                if dest.tiles.tiles.count < dest.tiles.capacity {
                    updateSpace(fromKey) {
                        $0.tiles.remove(w)
                        $0.zoomed = nil
                    }
                    dest.tiles.insert(w, active: nil)
                    spaces[pointKey] = dest
                    record(.drag)
                } else {
                    Notices.shared.show(String(localized: "That screen is full"), on: d)
                }
            }
        } else if fromKey == nil, let pointKey, tracked[w] != nil, !manualFloat.contains(w), !unfitFloat.contains(w) {
            updateSpace(pointKey) { $0.tiles.insert(w, active: nil) }
        }
        reconcile(force: true)
        activate(w)
    }

    /// The topmost tiled window under a point.
    func windowUnder(_ point: CGPoint, excluding: WindowID? = nil) -> WindowID? {
        for s in WindowServer.onScreen() where s.layer == 0 && s.id != excluding && s.bounds.contains(point) {
            if tracked[s.id] != nil { return s.id }
            if s.pid != ProcessInfo.processInfo.processIdentifier { return nil }
        }
        return nil
    }

    /// A tiled window whose edge is within a few points of the pointer.
    func tiledWindow(near point: CGPoint, slop: CGFloat = 8) -> WindowID? {
        tracked.values.first { t in isTiled(t.id) && t.frame.insetBy(dx: -slop, dy: -slop).contains(point) && !t.frame.insetBy(dx: slop, dy: slop).contains(point) }?.id
    }

    // MARK: - Room

    private func offerRoom(for t: TrackedWindow, display: Display, space: ScreenSpace) {
        guard !prefs.roomCardMuted.contains(t.bundleID) else { return }
        if let last = lastRoomCard[t.bundleID], Date().timeIntervalSince(last) < 86400 { return }
        lastRoomCard[t.bundleID] = Date()
        var options: [(String, () -> Void)] = []
        for (key, other) in currentKeys where other.id != display.id {
            let s = spaces[key] ?? ScreenSpace(capacity: prefs.windowsPerScreen)
            if s.tiles.tiles.count < s.tiles.capacity {
                options.append((String(localized: "Move to \(other.name)"), { [weak self] in
                    guard let self else { return }
                    self.unfitFloat.remove(t.id)
                    self.updateSpace(key) { $0.tiles.insert(t.id, active: nil) }
                    self.reconcile()
                }))
            }
        }
        let fewer = max(1, space.tiles.tiles.count)
        if let key = currentKeys.first(where: { $0.value.id == display.id })?.key, fewer < (space.countPick ?? prefs.windowsPerScreen) || fewer == 1 {
            options.append((fewer == 1 ? String(localized: "Use 1 window here") : String(localized: "Use \(fewer) windows here"), { [weak self] in
                guard let self else { return }
                self.unfitFloat.remove(t.id)
                self.updateSpace(key) {
                    $0.countPick = fewer
                    $0.tiles.insert(t.id, active: nil, placement: .mainTile, whenFull: self.prefs.whenFull)
                }
                self.reconcile()
            }))
        }
        RoomCard.shared.show(app: t.appName, bundleID: t.bundleID, near: t.element.frame ?? t.frame, options: options)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension WindowManager {
    static func name(of kind: LayoutKind) -> String {
        switch kind {
        case .grid: String(localized: "Grid")
        case .columns: String(localized: "Columns")
        case .rows: String(localized: "Rows")
        case .side: String(localized: "Side")
        }
    }
}
