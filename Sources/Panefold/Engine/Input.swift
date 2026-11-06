import AppKit
import PanefoldCore

/// Registers every shortcut with macOS and runs its action.
@MainActor
final class HotkeyBinder: ObservableObject {
    static let shared = HotkeyBinder()

    private var tokens: [UInt32] = []
    private var escapeToken: UInt32?
    /// Keys another app already holds.
    @Published private(set) var unavailable: Set<ShortcutAction> = []
    /// Keys macOS keeps for its own shortcuts.
    @Published private(set) var leftToMacOS: Set<ShortcutAction> = []
    /// Paused while a shortcut is being recorded in Settings, so pressing one records it.
    var paused = false { didSet { rebind() } }

    private var wm: WindowManager { .shared }

    func rebind() {
        HotkeyCenter.shared.unregisterAll(tokens)
        tokens.removeAll()
        HotkeyCenter.shared.clearFailures()
        var failed: Set<ShortcutAction> = []
        var system: Set<ShortcutAction> = []
        defer {
            if unavailable != failed { unavailable = failed }
            if leftToMacOS != system { leftToMacOS = system }
        }
        guard !paused, wm.prefs.shortcutsEnabled, wm.trusted, wm.prefs.onboardingDone else { return }
        let macOS = SystemState.systemShortcuts()
        for (action, combo) in wm.prefs.shortcuts.all {
            if macOS.contains(combo) {
                system.insert(action)
                continue
            }
            if let t = HotkeyCenter.shared.register(combo, handler: { [weak self] in self?.perform(action) }) {
                tokens.append(t)
            } else {
                failed.insert(action)
            }
            if action == .tabView {
                let back = KeyCombo(combo.keyCode, combo.modifiers.union(.shift))
                if let t = HotkeyCenter.shared.register(back, handler: { TabViewController.shared.trigger(backward: true) }) { tokens.append(t) }
            }
        }
        for setup in wm.setups {
            guard let combo = setup.shortcut else { continue }
            let id = setup.id
            if let t = HotkeyCenter.shared.register(combo, handler: { SetupRunner.shared.open(id) }) { tokens.append(t) }
        }
    }

    /// Esc is only ours while a setup's blur is up.
    func setEscape(_ handler: (() -> Void)?) {
        if let escapeToken { HotkeyCenter.shared.unregister(escapeToken) }
        escapeToken = handler.flatMap { HotkeyCenter.shared.register(KeyCombo(KeyCodes.escape, []), handler: $0) }
    }

    func perform(_ action: ShortcutAction) {
        if action != .toggleTiling, action != .cheatSheet, !wm.isActive { return }
        wm.record(.shortcut, detail: action.rawValue)
        switch action {
        case .toggleTiling: wm.toggleTiling()
        case .cheatSheet: CheatSheet.shared.toggle()
        case .swapLeft: wm.swap(.left)
        case .swapRight: wm.swap(.right)
        case .swapUp: wm.swap(.up)
        case .swapDown: wm.swap(.down)
        case .makePrimary: wm.makePrimary()
        case .nextWindow: wm.focusNeighbor(forward: true)
        case .previousWindow: wm.focusNeighbor(forward: false)
        case .nextInStack: wm.cycleStack(forward: true)
        case .previousInStack: wm.cycleStack(forward: false)
        case .tabView: TabViewController.shared.trigger(backward: false)
        case .grow: wm.resize(grow: true)
        case .shrink: wm.resize(grow: false)
        case .resetSizes: wm.resetSizes()
        case .layoutGrid, .layoutColumns, .layoutRows, .layoutSide: wm.setLayout(action.layoutValue!)
        case .count1, .count2, .count3, .count4, .count5: wm.setCount(action.countValue!)
        case .float: wm.toggleFloat()
        case .alwaysFloat: wm.alwaysFloat()
        case .focusMode: wm.toggleFocusMode()
        case .noPeek: wm.toggleNoPeek()
        case .cleanSpace: wm.toggleCleanSpace()
        case .retile: wm.retile()
        }
    }
}

/// Watches the mouse: ⌘-drag to swap, edge drags to resize, drops on another screen, the grip, hover focus.
@MainActor
final class MouseController {
    static let shared = MouseController()

    private var monitors: [Any] = []
    private var downWindow: WindowID?
    private var downFrame: CGRect?
    private var dragging = false
    private var hover = HoverFocusPolicy()
    private var hoverTimer: Timer?
    private var lastKeyTime: TimeInterval = 0
    private var wm: WindowManager { .shared }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .flagsChanged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(m) }
        updateHoverFocus()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func updateHoverFocus() {
        let on = wm.prefs.hoverFocus && wm.isActive
        if on, hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverTick() }
            }
            hoverTimer?.tolerance = 0.02
        } else if !on {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private func hoverTick() {
        let now = ProcessInfo.processInfo.systemUptime
        // Only how long ago a key was pressed, never which one.
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let keyTime = now - sinceKey
        if keyTime > lastKeyTime + 0.01 {
            lastKeyTime = keyTime
            hover.keyPressed(at: keyTime)
        }
        let p = Display.mouse
        let under = wm.windowUnder(p)
        if let w = hover.pointer(x: p.x, y: p.y, over: under, active: wm.activeWindow, buttonsDown: NSEvent.pressedMouseButtons != 0, at: now) {
            wm.activate(w)
        }
    }

    private func handle(_ e: NSEvent) {
        let p = Display.mouse
        switch e.type {
        case .leftMouseDown:
            if Overlays.shared.handleClick(at: p) { return }
            dragging = false
            // An edge drag starts a few points outside the window.
            downWindow = wm.windowUnder(p) ?? wm.tiledWindow(near: p)
            downFrame = downWindow.flatMap { wm.tracked[$0]?.element.frame }
            wm.mouseIsDown = true
        case .leftMouseDragged:
            dragging = true
            guard let w = downWindow, wm.isTiled(w) else { return }
            let flags = NSEvent.modifierFlags
            if flags.contains(.command), let frame = downFrame, wm.tracked[w]?.element.size.map({ abs($0.width - frame.width) < 2 && abs($0.height - frame.height) < 2 }) ?? true {
                let target = wm.windowUnder(p, excluding: w)
                let targetFrame = target.flatMap { t in wm.tracked[t]?.frame }
                Overlays.shared.showDrop(over: targetFrame, label: flags.contains(.option) ? String(localized: "Add to stack") : String(localized: "Swap"))
            } else {
                Overlays.shared.hideDrop()
            }
        case .leftMouseUp:
            wm.mouseIsDown = false
            Overlays.shared.hideDrop()
            defer {
                downWindow = nil
                downFrame = nil
                dragging = false
            }
            guard dragging, let w = downWindow, let before = downFrame, let after = wm.tracked[w]?.element.frame else {
                wm.scheduleReconcile(later: true)
                return
            }
            let resized = abs(after.width - before.width) > 2 || abs(after.height - before.height) > 2
            let moved = abs(after.minX - before.minX) > 2 || abs(after.minY - before.minY) > 2
            let flags = NSEvent.modifierFlags
            if resized, wm.isTiled(w) {
                wm.edgeDragged(w, from: before, to: after)
            } else if moved {
                wm.windowDropped(w, at: p, command: flags.contains(.command), option: flags.contains(.option))
            } else {
                wm.scheduleReconcile(later: true)
            }
        case .mouseMoved:
            Overlays.shared.pointerMoved(p)
        default:
            break
        }
    }
}

/// Names for shortcuts, as shown in Settings, the cheat sheet and the hover bar.
enum ShortcutText {
    static func name(_ a: ShortcutAction) -> String {
        switch a {
        case .toggleTiling: String(localized: "Turn tiling on or off")
        case .cheatSheet: String(localized: "Shortcut cheat sheet")
        case .swapLeft: String(localized: "Swap with the window on the left")
        case .swapRight: String(localized: "Swap with the window on the right")
        case .swapUp: String(localized: "Swap with the window above")
        case .swapDown: String(localized: "Swap with the window below")
        case .makePrimary: String(localized: "Make the active window primary")
        case .nextWindow: String(localized: "Activate the next window")
        case .previousWindow: String(localized: "Activate the previous window")
        case .nextInStack: String(localized: "Next window in this tile")
        case .previousInStack: String(localized: "Previous window in this tile")
        case .tabView: String(localized: "Window switcher")
        case .grow: String(localized: "Make the active window bigger")
        case .shrink: String(localized: "Make the active window smaller")
        case .resetSizes: String(localized: "Reset sizes on this screen")
        case .layoutGrid: String(localized: "Grid layout")
        case .layoutColumns: String(localized: "Columns layout")
        case .layoutRows: String(localized: "Rows layout")
        case .layoutSide: String(localized: "Side layout")
        case .count1: String(localized: "Tile 1 window")
        case .count2: String(localized: "Tile up to 2 windows")
        case .count3: String(localized: "Tile up to 3 windows")
        case .count4: String(localized: "Tile up to 4 windows")
        case .count5: String(localized: "Tile up to 5 windows")
        case .float: String(localized: "Float or tile the active window")
        case .alwaysFloat: String(localized: "Always float windows like this one")
        case .focusMode: String(localized: "Focus mode")
        case .noPeek: String(localized: "No peek mode")
        case .cleanSpace: String(localized: "Clean Space")
        case .retile: String(localized: "Retile")
        }
    }

    static func groupName(_ g: ShortcutAction.Group) -> String {
        switch g {
        case .general: String(localized: "Panefold")
        case .move: String(localized: "Move")
        case .activate: String(localized: "Activate")
        case .size: String(localized: "Size")
        case .layout: String(localized: "Layout")
        case .more: String(localized: "More")
        }
    }
}
