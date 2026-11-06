import AppKit
import SwiftUI
import PanefoldCore

/// Short notices at the bottom of the screen: "Maximum size reached", "Grid", "This Space is full".
@MainActor
final class Notices {
    static let shared = Notices()
    private var panel: OverlayPanel?
    private var hide: DispatchWorkItem?

    func show(_ text: String, on display: Display?) {
        guard let d = display ?? WindowManager.shared.pointerScreen?.display ?? Display.all().first else { return }
        let panel = self.panel ?? {
            let p = OverlayPanel(level: .statusBar)
            self.panel = p
            return p
        }()
        let view = NoticeView(text: text)
        let size = NSHostingView(rootView: view).fittingSize
        panel.host(view)
        panel.place(CGRect(x: d.visible.midX - size.width / 2, y: d.visible.maxY - size.height - 48, width: size.width, height: size.height))
        panel.alphaValue = 1
        panel.orderFront(nil)
        hide?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel?.animator().alphaValue = 0 }, completionHandler: { panel?.orderOut(nil) })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

private struct NoticeView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A card that asks one question near a window and closes by itself if left alone.
@MainActor
class CardController {
    fileprivate var panel: OverlayPanel?
    private var timeout: DispatchWorkItem?
    fileprivate var hovering = false

    func present<V: View>(_ view: V, near frame: CGRect, seconds: TimeInterval) {
        let panel = self.panel ?? {
            let p = OverlayPanel(clickThrough: false, level: .floating)
            self.panel = p
            return p
        }()
        let size = NSHostingView(rootView: view).fittingSize
        panel.host(view)
        panel.place(CGRect(x: frame.midX - size.width / 2, y: frame.minY + 36, width: size.width, height: size.height))
        panel.orderFront(nil)
        schedule(seconds)
    }

    private func schedule(_ seconds: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hovering { self.schedule(2) } else { self.dismiss() }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismiss() {
        timeout?.cancel()
        panel?.orderOut(nil)
    }
}

@MainActor
final class ConfirmCard: CardController {
    static let shared = ConfirmCard()

    func ask(_ question: String, detail: String, confirm: String, near frame: CGRect, onConfirm: @escaping () -> Void) {
        present(CardView(title: question, detail: detail, buttons: [
            (String(localized: "Not now"), false, { [weak self] in self?.dismiss() }),
            (confirm, true, { [weak self] in
                onConfirm()
                self?.dismiss()
            }),
        ], hover: { [weak self] in self?.hovering = $0 }), near: frame, seconds: 12)
    }
}

/// "Needs more room": a window floats because its app can't get small enough for the layout.
@MainActor
final class RoomCard: CardController {
    static let shared = RoomCard()

    func show(app: String, bundleID: String, near frame: CGRect, options: [(String, () -> Void)]) {
        var buttons: [(String, Bool, () -> Void)] = options.enumerated().map { i, o in
            (o.0, i == 0, { [weak self] in
                o.1()
                self?.dismiss()
            })
        }
        buttons.append((String(localized: "Keep it floating"), options.isEmpty, { [weak self] in self?.dismiss() }))
        present(CardView(
            title: String(localized: "\(app) needs more room"),
            detail: String(localized: "It can't get small enough for this layout, so it floats."),
            buttons: buttons,
            footer: (String(localized: "Don't show again for \(app)"), { [weak self] in
                WindowManager.shared.prefs.roomCardMuted.insert(bundleID)
                self?.dismiss()
            }),
            hover: { [weak self] in self?.hovering = $0 }
        ), near: frame, seconds: 7)
    }
}

private struct CardView: View {
    let title: String
    let detail: String
    let buttons: [(String, Bool, () -> Void)]
    var footer: (String, () -> Void)?
    let hover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").foregroundStyle(.tint)
                Text(title).font(.headline)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let footer {
                    Button(footer.0, action: footer.1).buttonStyle(.link).font(.caption)
                }
                Spacer(minLength: 12)
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in
                    if b.1 {
                        Button(b.0, action: b.2).buttonStyle(.borderedProminent)
                    } else {
                        Button(b.0, action: b.2)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
        .onHover(perform: hover)
        .padding(10)
    }
}

/// Every shortcut, with the user's own keys, over the screen they're on.
@MainActor
final class CheatSheet {
    static let shared = CheatSheet()
    private var panel: OverlayPanel?
    private var monitors: [Any] = []

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard let d = WindowManager.shared.pointerScreen?.display else { return }
        let panel = self.panel ?? {
            let p = OverlayPanel(clickThrough: false, level: .modalPanel)
            p.keyable = true
            self.panel = p
            return p
        }()
        panel.host(CheatSheetView { [weak self] in self?.hide() })
        let size = CGSize(width: min(880, d.visible.width - 80), height: min(640, d.visible.height - 80))
        panel.place(CGRect(x: d.visible.midX - size.width / 2, y: d.visible.midY - size.height / 2, width: size.width, height: size.height))
        panel.makeKeyAndOrderFront(nil)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {
                self?.hide()
                return nil
            }
            return e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        } as Any)
    }

    func hide() {
        panel?.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

struct CheatSheetView: View {
    let close: () -> Void
    @ObservedObject private var wm = WindowManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Shortcuts").font(.title2.bold())
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }.buttonStyle(.borderless)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 18) {
                    ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ShortcutText.groupName(group)).font(.headline).foregroundStyle(.secondary)
                            ForEach(ShortcutAction.allCases.filter { $0.group == group }, id: \.self) { a in
                                HStack {
                                    Text(ShortcutText.name(a)).font(.callout)
                                    Spacer()
                                    Text(wm.prefs.shortcuts.combo(a)?.label ?? String(localized: "Off"))
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                }
                            }
                        }
                    }
                }
            }
            Text("Hold ⌘ and drag a window onto another to swap them. Add ⌥ to stack it there.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}

/// The menu bar icon: four rounded panes, filled while tiling, outlined otherwise, with a dot during Clean Space.
@MainActor
final class MenuBarIcon: ObservableObject {
    static let shared = MenuBarIcon()
    @Published private(set) var image = MenuBarIcon.draw(filled: false, mark: false)
    private var state: (Bool, Bool)?

    func update(filled: Bool, cleanSpace: Bool) {
        guard state.map({ $0 != (filled, cleanSpace) }) ?? true else { return }
        state = (filled, cleanSpace)
        image = Self.draw(filled: filled, mark: cleanSpace)
    }

    static func draw(filled: Bool, mark: Bool) -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 16), flipped: true) { _ in
            let pane: CGFloat = 6.2, gap: CGFloat = 1.8, origin = CGPoint(x: 2, y: 1.5)
            for row in 0..<2 {
                for col in 0..<2 {
                    let r = CGRect(x: origin.x + CGFloat(col) * (pane + gap), y: origin.y + CGFloat(row) * (pane + gap), width: pane, height: pane)
                    let path = NSBezierPath(roundedRect: filled ? r : r.insetBy(dx: 0.6, dy: 0.6), xRadius: 1.8, yRadius: 1.8)
                    NSColor.black.set()
                    if filled { path.fill() } else {
                        path.lineWidth = 1.2
                        path.stroke()
                    }
                }
            }
            if mark {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: CGRect(x: 13.5, y: 0, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
