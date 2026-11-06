import AppKit
import SwiftUI
import PanefoldCore

/// A borderless panel that never takes focus. Used for every overlay Panefold draws.
class OverlayPanel: NSPanel {
    var keyable = false

    init(clickThrough: Bool = true, level: NSWindow.Level = .normal) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = clickThrough
        self.level = level
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenNone]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    /// Sets the frame from top-left-origin coordinates.
    func place(_ r: CGRect) {
        let cocoa = Display.toCocoa(r)
        if frame != cocoa { setFrame(cocoa, display: true) }
    }

    func host<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

/// Draws a closure. Cheaper than a hosting view for simple shapes.
final class DrawingView: NSView {
    var painter: (CGRect) -> Void = { _ in } { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { painter(bounds) }
    override var isFlipped: Bool { true }
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    static func highlight(_ c: HighlightColor) -> NSColor {
        c.rgb.map { NSColor(rgb: $0) } ?? .controlAccentColor
    }
}

@MainActor
final class Overlays {
    static let shared = Overlays()

    private var borders: [WindowID: OverlayPanel] = [:]
    private var dimmers: [String: OverlayPanel] = [:]
    private var cleanBackground: OverlayPanel?
    private var marks: [String: OverlayPanel] = [:]
    private var grip: OverlayPanel?
    private var drop: OverlayPanel?
    /// Click targets for stack marks: clicking one shows that window.
    private var markHits: [(CGRect, WindowID)] = []
    private var gripRect: CGRect?
    private var gripWindow: WindowID?
    private var restingSince: Date?
    private let bar = HoverBarController()

    private var wm: WindowManager { .shared }

    func update() {
        let prefs = wm.prefs
        let working = wm.status.isWorking
        updateBorders(working ? prefs.highlight : .none, prefs: prefs)
        updateNoPeek(working && prefs.noPeek, prefs: prefs)
        updateCleanSpace(working)
        updateMarks(working, prefs: prefs)
    }

    // MARK: Borders and glow

    private func updateBorders(_ highlight: Highlight, prefs: Preferences) {
        var wanted: [WindowID] = []
        switch highlight {
        case .none: break
        case .borderActive, .glowActive:
            if let a = wm.activeWindow, wm.isTiled(a) { wanted = [a] }
        case .borderAll:
            wanted = wm.screens.flatMap { $0.tiles.map(\.showing) }
        }
        for (w, panel) in borders where !wanted.contains(w) {
            panel.orderOut(nil)
            borders[w] = nil
        }
        let color = NSColor.highlight(prefs.highlightColor)
        for w in wanted {
            guard let frame = frame(of: w) else { continue }
            let panel = borders[w] ?? {
                let p = OverlayPanel()
                p.contentView = DrawingView()
                borders[w] = p
                return p
            }()
            let width = prefs.borderWidth
            let isActive = w == wm.activeWindow
            if highlight == .glowActive {
                panel.place(CGRect(x: frame.minX + 10, y: frame.minY - 4, width: max(0, frame.width - 20), height: 4))
                (panel.contentView as? DrawingView)?.painter = { rect in
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0.5), xRadius: 2, yRadius: 2)
                    let gradient = NSGradient(colors: [color.withAlphaComponent(0), color, color.withAlphaComponent(0)])
                    gradient?.draw(in: path, angle: 0)
                }
            } else {
                panel.place(frame.insetBy(dx: -width, dy: -width))
                (panel.contentView as? DrawingView)?.painter = { rect in
                    let inset = rect.insetBy(dx: width / 2, dy: width / 2)
                    let path = NSBezierPath(roundedRect: inset, xRadius: 12 + width / 2, yRadius: 12 + width / 2)
                    path.lineWidth = width
                    (isActive || highlight == .borderActive ? color : color.withAlphaComponent(0.45)).setStroke()
                    path.stroke()
                }
            }
            panel.order(.above, relativeTo: Int(w))
        }
    }

    private func frame(of w: WindowID) -> CGRect? {
        for s in wm.screens {
            guard let i = s.tiles.firstIndex(where: { $0.windows.contains(w) }), let f = s.tileFrames[safe: i] else { continue }
            if s.zoomed == w { return s.display.geometry(insets: wm.prefs.insets(for: s.display.id)).area.insetBy(dx: wm.prefs.effectiveGap, dy: wm.prefs.effectiveGap) }
            return f
        }
        return nil
    }

    // MARK: No peek

    private func updateNoPeek(_ on: Bool, prefs: Preferences) {
        guard on, let active = wm.activeWindow else {
            dimmers.values.forEach { $0.orderOut(nil) }
            return
        }
        let ids = Set(wm.screens.map(\.display.id))
        for (id, p) in dimmers where !ids.contains(id) {
            p.orderOut(nil)
            dimmers[id] = nil
        }
        let style = "\(prefs.blurOthers)-\(prefs.dimAmount)"
        for s in wm.screens {
            let panel = dimmers[s.display.id] ?? {
                let p = OverlayPanel()
                dimmers[s.display.id] = p
                return p
            }()
            if panel.identifier?.rawValue != style {
                panel.identifier = NSUserInterfaceItemIdentifier(style)
                let container = NSView()
                if prefs.blurOthers {
                    let blur = NSVisualEffectView()
                    blur.material = .fullScreenUI
                    blur.blendingMode = .behindWindow
                    blur.state = .active
                    blur.autoresizingMask = [.width, .height]
                    container.addSubview(blur)
                }
                let dim = NSView()
                dim.wantsLayer = true
                dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(prefs.dimAmount).cgColor
                dim.autoresizingMask = [.width, .height]
                container.addSubview(dim)
                panel.contentView = container
            }
            panel.place(s.display.frame)
            panel.contentView?.subviews.forEach { $0.frame = panel.contentView?.bounds ?? .zero }
            panel.order(.below, relativeTo: Int(active))
        }
    }

    // MARK: Clean Space

    private func updateCleanSpace(_ working: Bool) {
        guard working, let key = wm.cleanSpaceKey, let s = wm.screens.first(where: { $0.key == key }) else {
            cleanBackground?.orderOut(nil)
            return
        }
        let panel = cleanBackground ?? {
            let p = OverlayPanel()
            let v = NSView()
            v.wantsLayer = true
            p.contentView = v
            cleanBackground = p
            return p
        }()
        panel.contentView?.layer?.backgroundColor = NSColor(rgb: wm.prefs.cleanBackground.rgb).cgColor
        panel.place(s.display.visible)
        // Behind the backmost window showing in Clean Space.
        let showing = Set(s.tiles.map(\.showing))
        if let back = WindowServer.onScreen().last(where: { showing.contains($0.id) || $0.id == wm.activeWindow }) {
            panel.order(.below, relativeTo: Int(back.id))
        } else {
            panel.orderFront(nil)
        }
    }

    // MARK: Grip and stack marks

    private func updateMarks(_ working: Bool, prefs: Preferences) {
        markHits.removeAll()
        var used: Set<String> = []
        gripRect = nil
        gripWindow = nil
        guard working else {
            marks.values.forEach { $0.orderOut(nil) }
            grip?.orderOut(nil)
            bar.hide()
            return
        }
        let gap = prefs.effectiveGap
        for s in wm.screens {
            for (i, tile) in s.tiles.enumerated() {
                guard let f = s.tileFrames[safe: i], s.zoomed == nil || s.zoomed == tile.showing else { continue }
                let frame = s.zoomed == tile.showing ? (self.frame(of: tile.showing) ?? f) : f
                let isActive = tile.windows.contains(wm.activeWindow ?? 0)
                let showGrip = isActive && prefs.quickActions
                guard tile.isStacked || showGrip else { continue }
                let id = "\(s.key)/\(i)"
                used.insert(id)
                let panel = marks[id] ?? {
                    let p = OverlayPanel()
                    p.contentView = DrawingView()
                    marks[id] = p
                    return p
                }()
                let segment: CGFloat = 14, shown: CGFloat = 26, spacing: CGFloat = 4, height: CGFloat = 5
                let count = tile.windows.count
                let width = tile.isStacked ? CGFloat(count - 1) * (segment + spacing) + shown : 40
                let y = frame.minY - max(height + 1, gap / 2 + height / 2)
                let rect = CGRect(x: frame.midX - width / 2, y: max(y, frame.minY - height - 1), width: width, height: height)
                panel.place(rect.insetBy(dx: -2, dy: -2))
                var segments: [(CGRect, WindowID, Bool)] = []
                if tile.isStacked {
                    var x: CGFloat = 2
                    // Marks keep a fixed order, so a window's mark stays put while you switch.
                    for w in tile.windows.sorted() {
                        let isShowing = w == tile.showing
                        let r = CGRect(x: x, y: 2, width: isShowing ? shown : segment, height: height)
                        segments.append((r, w, isShowing))
                        markHits.append((CGRect(x: rect.minX + x - 2, y: rect.minY - 6, width: r.width + 4, height: height + 12), w))
                        x += r.width + spacing
                    }
                }
                (panel.contentView as? DrawingView)?.painter = { _ in
                    if segments.isEmpty {
                        NSColor.white.withAlphaComponent(0.55).setFill()
                        NSBezierPath(roundedRect: CGRect(x: 2, y: 2, width: width, height: height), xRadius: 2.5, yRadius: 2.5).fill()
                    } else {
                        for (r, _, isShowing) in segments {
                            NSColor.systemOrange.withAlphaComponent(isShowing ? 1 : (isActive ? 0.55 : 0.4)).setFill()
                            NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
                        }
                    }
                }
                panel.order(.above, relativeTo: Int(tile.showing))
                if showGrip {
                    gripRect = rect.insetBy(dx: -8, dy: -8)
                    gripWindow = wm.activeWindow
                }
            }
        }
        for (id, p) in marks where !used.contains(id) {
            p.orderOut(nil)
            marks[id] = nil
        }
        if let w = gripWindow, bar.isShown, bar.window != w { bar.hide() }
        if gripWindow == nil { bar.hide() }
    }

    /// A click on a stack mark shows that window. Returns true if the click was on one.
    func handleClick(at p: CGPoint) -> Bool {
        guard let hit = markHits.first(where: { $0.0.contains(p) }) else { return false }
        wm.show(hit.1)
        wm.record(.hoverBar)
        return true
    }

    /// Opens the quick-action bar when the pointer rests on the grip.
    func pointerMoved(_ p: CGPoint) {
        if bar.isShown {
            bar.pointerMoved(p, grip: gripRect)
            return
        }
        guard let rect = gripRect, let w = gripWindow, rect.contains(p) else {
            restingSince = nil
            return
        }
        if restingSince == nil {
            restingSince = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, let since = self.restingSince, Date().timeIntervalSince(since) >= 0.3,
                      let rect = self.gripRect, rect.contains(Display.mouse), let frame = self.frame(of: w) else { return }
                self.bar.show(for: w, above: frame)
            }
        }
    }

    // MARK: Drag feedback

    func showDrop(over frame: CGRect?, label: String) {
        guard let frame else {
            drop?.orderOut(nil)
            return
        }
        let panel = drop ?? {
            let p = OverlayPanel(level: .floating)
            drop = p
            return p
        }()
        panel.host(DropHighlight(label: label))
        panel.place(frame)
        panel.orderFront(nil)
    }

    func hideDrop() { drop?.orderOut(nil) }
}

private struct DropHighlight: View {
    let label: String
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 3))
            .overlay(
                Text(label).font(.title3.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            )
    }
}
