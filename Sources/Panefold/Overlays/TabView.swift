import AppKit
import SwiftUI
import PanefoldCore

/// Every window, screen by screen, laid out as they sit on the desktop. Hold ⌥ and press ⇥ to move along,
/// let go to switch. Titles are read only while it's open and are never kept.
@MainActor
final class TabViewController: ObservableObject {
    static let shared = TabViewController()

    struct Item: Identifiable, Equatable {
        let id: WindowID
        let pid: pid_t
        let appName: String
        let title: String
        let frame: CGRect
        let displayID: String
        let minimized: Bool
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var displays: [Display] = []
    @Published var selected: WindowID?
    private var order: [WindowID] = []
    private var panel: OverlayPanel?
    private var poll: Timer?
    private var keyMonitor: Any?
    /// Elements found while open, so a minimized window can be brought back.
    private static var elements: [WindowID: TrackedWindow] = [:]
    /// The modifier keys that keep it open.
    private var hold: NSEvent.ModifierFlags = .option

    var isShown: Bool { panel?.isVisible == true }

    static func element(for w: WindowID) -> TrackedWindow? { elements[w] }

    func trigger(backward: Bool) {
        if isShown {
            step(backward ? -1 : 1)
        } else {
            open(backward: backward)
        }
    }

    private func open(backward: Bool) {
        let wm = WindowManager.shared
        if let combo = wm.prefs.shortcuts.combo(.tabView) {
            var f: NSEvent.ModifierFlags = []
            if combo.modifiers.contains(.option) { f.insert(.option) }
            if combo.modifiers.contains(.command) { f.insert(.command) }
            if combo.modifiers.contains(.control) { f.insert(.control) }
            hold = f.isEmpty ? .option : f
        }
        collect()
        guard !items.isEmpty else { return }
        // Windows in the order they were last used; a quick tap goes back to the previous one.
        let mru = wm.mru
        order = items.map(\.id).sorted { (mru.firstIndex(of: $0) ?? .max) < (mru.firstIndex(of: $1) ?? .max) }
        let current = wm.activeWindow.flatMap { order.firstIndex(of: $0) } ?? -1
        selected = order[((current + (backward ? -1 : 1)) % order.count + order.count) % order.count]

        let union = displays.reduce(CGRect.null) { $0.union($1.frame) }
        guard let host = Display.containing(Display.mouse, in: displays) else { return }
        let maxW = host.visible.width * 0.86, maxH = host.visible.height * 0.8
        let scale = min(maxW / union.width, (maxH - 60) / union.height, 0.5)
        let size = CGSize(width: union.width * scale + 40, height: union.height * scale + 110)
        let panel = self.panel ?? {
            let p = OverlayPanel(clickThrough: false, level: .modalPanel)
            p.keyable = true
            self.panel = p
            return p
        }()
        panel.host(TabMap(controller: self, union: union, scale: scale))
        panel.place(CGRect(x: host.visible.midX - size.width / 2, y: host.visible.midY - size.height / 2, width: size.width, height: size.height))
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 53: self.close(switching: false)
            case 36, 76: self.close(switching: true)
            case 48: self.step(e.modifierFlags.contains(.shift) ? -1 : 1)
            case 123: self.move(.left)
            case 124: self.move(.right)
            case 125: self.move(.down)
            case 126: self.move(.up)
            default: return e
            }
            return nil
        }
        // Let go of the held keys to switch, like ⌘-Tab.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.modifierFlags.intersection(self.hold).isEmpty { self.close(switching: true) }
            }
        }
    }

    private func collect() {
        displays = Display.all()
        var out: [Item] = []
        Self.elements.removeAll()
        let onScreen = Set(WindowServer.onScreen().filter { $0.layer == 0 }.map(\.id))
        let own = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != own {
            let ax = AX.app(app.processIdentifier)
            for w in ax.windows {
                guard let id = w.windowID, w.subrole == kAXStandardWindowSubrole || w.subrole == kAXDialogSubrole else { continue }
                let minimized = w.isMinimized
                guard minimized || onScreen.contains(id), let frame = w.frame else { continue }
                let display = Display.containing(frame, in: displays)
                out.append(Item(id: id, pid: app.processIdentifier, appName: app.localizedName ?? "", title: w.title ?? "",
                                frame: frame, displayID: display?.id ?? "", minimized: minimized))
                Self.elements[id] = TrackedWindow(id: id, element: w, pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
                                                  appName: app.localizedName ?? "", frame: frame)
            }
        }
        items = out
    }

    private func step(_ delta: Int) {
        guard !order.isEmpty else { return }
        let i = selected.flatMap { order.firstIndex(of: $0) } ?? 0
        selected = order[((i + delta) % order.count + order.count) % order.count]
    }

    private func move(_ d: Direction) {
        guard let s = items.first(where: { $0.id == selected }) else { return }
        let candidates = items.filter { $0.id != s.id && !$0.minimized }.map { ($0.id, $0.frame) }
        if let next = Navigator.nearest(from: s.frame, in: candidates, direction: d) { selected = next }
    }

    func pick(_ id: WindowID) {
        selected = id
        close(switching: true)
    }

    func close(switching: Bool) {
        poll?.invalidate()
        poll = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        if switching, let id = selected { WindowManager.shared.activate(id) }
        // Titles were only for the labels.
        items = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.elements.removeAll() }
    }
}

private struct TabMap: View {
    @ObservedObject var controller: TabViewController
    let union: CGRect
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                ForEach(controller.displays) { d in
                    let r = map(d.frame)
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    let minimized = controller.items.filter { $0.minimized && $0.displayID == d.id }
                    HStack(spacing: 6) {
                        ForEach(minimized) { item in thumb(item, compact: true) }
                    }
                    .offset(x: r.minX + 8, y: r.maxY - 40)
                }
                ForEach(controller.items.filter { !$0.minimized }) { item in
                    let r = map(item.frame)
                    thumb(item, compact: false).frame(width: max(r.width - 4, 40), height: max(r.height - 4, 30)).offset(x: r.minX + 2, y: r.minY + 2)
                }
            }
            .frame(width: union.width * scale, height: union.height * scale, alignment: .topLeading)
            if let s = controller.items.first(where: { $0.id == controller.selected }) {
                Text(s.title.isEmpty ? s.appName : "\(s.appName) — \(s.title)").font(.headline).lineLimit(1)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }

    private func map(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - union.minX) * scale, y: (r.minY - union.minY) * scale, width: r.width * scale, height: r.height * scale)
    }

    @ViewBuilder
    private func thumb(_ item: TabViewController.Item, compact: Bool) -> some View {
        let selected = item.id == controller.selected
        let icon = NSRunningApplication(processIdentifier: item.pid)?.icon
        VStack(spacing: 4) {
            if let icon { Image(nsImage: icon).resizable().frame(width: compact ? 22 : 36, height: compact ? 22 : 36) }
            if !compact {
                Text(item.appName).font(.caption.weight(.semibold)).lineLimit(1)
                Text(item.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(compact ? 4 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.45) : .black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .white.opacity(0.1), lineWidth: selected ? 2 : 1))
        .fixedSize(horizontal: compact, vertical: compact)
        .onTapGesture { controller.pick(item.id) }
    }
}
