import AppKit
import SwiftUI
import PanefoldCore

/// The bar of quick actions that opens when the pointer rests on the grip above the active window.
@MainActor
final class HoverBarController {
    private var panel: OverlayPanel?
    private(set) var window: WindowID?
    private var leftAt: Date?
    var isShown: Bool { panel?.isVisible == true }

    func show(for w: WindowID, above frame: CGRect) {
        window = w
        let panel = self.panel ?? {
            let p = OverlayPanel(clickThrough: false, level: .floating)
            self.panel = p
            return p
        }()
        let model = HoverBarModel(window: w)
        let size = NSHostingView(rootView: HoverBar(model: model, close: {})).fittingSize
        panel.host(HoverBar(model: model) { [weak self] in self?.hide() })
        let x = min(max(frame.midX - size.width / 2, frame.minX), frame.maxX - size.width)
        panel.place(CGRect(x: x, y: frame.minY + 6, width: size.width, height: size.height))
        panel.orderFront(nil)
        leftAt = nil
    }

    func pointerMoved(_ p: CGPoint, grip: CGRect?) {
        guard let panel else { return }
        let inside = Display.fromCocoa(panel.frame).insetBy(dx: -12, dy: -12).contains(p) || grip?.contains(p) == true
        if inside {
            leftAt = nil
        } else if leftAt == nil {
            leftAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, let left = self.leftAt, Date().timeIntervalSince(left) >= 0.4 else { return }
                self.hide()
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        window = nil
    }
}

@MainActor
final class HoverBarModel: ObservableObject {
    let window: WindowID
    @Published var option = NSEvent.modifierFlags.contains(.option)
    private var monitor: Any?

    init(window: WindowID) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.option = e.modifierFlags.contains(.option)
            return e
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    var wm: WindowManager { .shared }
    var located: (key: String, display: Display)? { wm.locate(window) }
    var screen: ScreenSnapshot? { located.flatMap { l in wm.screens.first { $0.key == l.key } } }
    var tile: Tile? { screen?.tiles.first { $0.windows.contains(window) } }
    var isFloating: Bool { wm.isFloating(window) }
    var isZoomed: Bool { screen?.zoomed == window }
    var otherScreens: [ScreenSnapshot] { wm.screens.filter { $0.key != located?.key } }

    func shortcut(_ a: ShortcutAction) -> String { wm.prefs.shortcuts.combo(a)?.label ?? "" }
}

struct HoverBar: View {
    @ObservedObject var model: HoverBarModel
    let close: () -> Void
    private var wm: WindowManager { .shared }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                if !model.isFloating {
                    action("Primary", "rectangle.lefthalf.filled", .makePrimary) { wm.makePrimary() }
                    action(model.isZoomed ? "Exit focus" : "Focus", model.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", .focusMode) {
                        wm.toggleFocusMode()
                    }
                    if model.otherScreens.count == 1, let other = model.otherScreens.first {
                        action("Next screen", "rectangle.portrait.and.arrow.right", nil, help: help(for: other)) {
                            wm.moveWindow(model.window, toScreen: other.key)
                        }
                    } else if model.otherScreens.count > 1 {
                        Menu {
                            ForEach(model.otherScreens) { s in
                                Button("\(s.display.name): \(help(for: s))") { wm.moveWindow(model.window, toScreen: s.key) }
                            }
                        } label: {
                            Label("Move to", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .padding(.horizontal, 6)
                    }
                }
                if model.option {
                    action("Always float", "pin", .alwaysFloat) { wm.alwaysFloat(model.window) }
                } else {
                    action(model.isFloating ? "Tile" : "Float", model.isFloating ? "square.grid.2x2" : "macwindow.on.rectangle", .float) {
                        wm.toggleFloat(model.window)
                    }
                }
            }
            if let tile = model.tile, tile.isStacked {
                StackChips(tile: tile, window: model.window, close: close)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    private func help(for s: ScreenSnapshot) -> String {
        let used = s.tiles.count
        if used < s.capacity { return String(localized: "Room for \(s.capacity - used) more") }
        return wm.prefs.movingIntoFull == .swap ? String(localized: "Full: swaps places") : String(localized: "Full: stacks on top")
    }

    private func action(_ title: LocalizedStringKey, _ symbol: String, _ shortcut: ShortcutAction?, help: String? = nil, run: @escaping () -> Void) -> some View {
        Button {
            run()
            wm.record(.hoverBar)
            close()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                Text(title).font(.caption)
                if let shortcut, !model.shortcut(shortcut).isEmpty {
                    Text(model.shortcut(shortcut)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 64)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .help(help ?? "")
    }
}

struct BarButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(configuration.isPressed ? 0.2 : (hover ? 0.1 : 0))))
            .onHover { hover = $0 }
    }
}

/// The windows of a stacked tile, as chips: click to show, × or middle-click to close, drag onto another tile to move.
private struct StackChips: View {
    let tile: Tile
    let window: WindowID
    let close: () -> Void
    private var wm: WindowManager { .shared }

    var body: some View {
        HStack(spacing: 4) {
            Button { wm.cycleStack(forward: false, of: window) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            ForEach(tile.windows.sorted(), id: \.self) { w in
                Chip(window: w, showing: w == tile.showing, close: close)
            }
            Button { wm.cycleStack(forward: true, of: window) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
        }
        .onScrollWheel { wm.cycleStack(forward: $0 < 0, of: window) }
    }
}

private struct Chip: View {
    let window: WindowID
    let showing: Bool
    let close: () -> Void
    @State private var hover = false
    @State private var drag: CGSize = .zero
    private var wm: WindowManager { .shared }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = wm.appIcon(window) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
            Text(wm.appName(window) ?? "").font(.caption).lineLimit(1).frame(maxWidth: 90)
            if hover {
                Button { closeWindow() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(showing ? Color.orange.opacity(0.35) : .white.opacity(hover ? 0.12 : 0.06)))
        .offset(drag)
        .onHover { hover = $0 }
        .onTapGesture { wm.show(window) }
        .onMiddleClick { closeWindow() }
        .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { drag = $0.translation }
            .onEnded { _ in
                drag = .zero
                let p = Display.mouse
                if let target = wm.windowUnder(p, excluding: window), let found = wm.locate(target) {
                    _ = found
                    wm.moveIntoTile(window, of: target)
                    close()
                }
            })
    }

    private func closeWindow() {
        guard let t = wm.tracked[window] else { return }
        if !t.element.pressClose() {
            Notices.shared.show(String(localized: "\(t.appName) doesn't offer a close button for this window"), on: nil)
        }
    }
}

extension View {
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View { background(ScrollCatcher(action: action)) }
    func onMiddleClick(_ action: @escaping () -> Void) -> some View { background(MiddleClickCatcher(action: action)) }
}

private struct ScrollCatcher: NSViewRepresentable {
    let action: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { View(action: action) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class View: NSView {
        let action: (CGFloat) -> Void
        private var accumulated: CGFloat = 0
        init(action: @escaping (CGFloat) -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func scrollWheel(with e: NSEvent) {
            accumulated += e.scrollingDeltaY + e.scrollingDeltaX
            if abs(accumulated) > 12 {
                action(accumulated)
                accumulated = 0
            }
        }
    }
}

private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView { View(action: action) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class View: NSView {
        let action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func otherMouseUp(with e: NSEvent) { if e.buttonNumber == 2 { action() } }
    }
}

extension WindowManager {
    /// Moves a window from a stack's chip onto another tile: it shows on top there.
    func moveIntoTile(_ w: WindowID, of target: WindowID) {
        guard let from = locate(w)?.key, let to = locate(target)?.key else { return }
        if from == to {
            updateSpace(from) { $0.tiles.stack(w, onto: target) }
        } else {
            updateSpace(from) { $0.tiles.remove(w) }
            updateSpace(to) { $0.tiles.stack(w, onto: target) }
        }
        reconcile(force: true)
        activate(w)
    }
}
