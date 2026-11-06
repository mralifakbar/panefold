import AppKit
import SwiftUI
import PanefoldCore

/// The welcome tour. Nothing on screen moves until the last step's Tidy My Workspace.
struct OnboardingView: View {
    let close: () -> Void
    @EnvironmentObject var wm: WindowManager
    @State private var step = 0
    @State private var settled = false
    @State private var keyboard = true

    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: features
                case 3: makeItYours
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44).padding(.top, 36)
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? Color.accentColor : Color.primary.opacity(0.15)).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0, step < steps - 1 { Button(String(localized: "Back")) { withAnimation { step -= 1 } } }
                if step < steps - 1 {
                    Button(step == 0 ? String(localized: "Use Panefold") : String(localized: "Continue")) { withAnimation { step += 1 } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(step == 1 && !wm.trusted)
                }
            }
            .padding(20)
        }
        .frame(width: 720, height: 540)
        .onAppear {
            if wm.prefs.onboardingDone, !wm.trusted { step = 1 }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8)
                        .fill([Color.blue, .teal, .orange, .pink][i].opacity(0.75))
                        .frame(width: settled ? (i == 0 ? 150 : 150) : 170, height: settled ? (i == 0 ? 210 : 101) : 120)
                        .offset(settled ? [CGSize(width: -79, height: 0), CGSize(width: 79, height: -55), CGSize(width: 79, height: 55), .zero][i]
                                : CGSize(width: CGFloat(i * 18 - 27), height: CGFloat(i * 14 - 21)))
                        .opacity(settled && i == 3 ? 0 : 1)
                        .shadow(radius: 4)
                }
            }
            .frame(height: 230)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation(.spring(duration: 0.8)) { settled = true } }
            }
            Text("Your windows, in their place.").font(.system(size: 30, weight: .bold))
            Text("Open a window and Panefold gives it a place. Close one and the rest fill the space. No dragging, no resizing, no layouts to draw.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("One permission").font(.largeTitle.bold())
            Text("macOS lets an app move and resize other apps' windows only after you allow it under Accessibility. Panefold reads where windows are and how big, and moves them. Nothing else, and nothing leaves your Mac.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Image(systemName: wm.trusted ? "checkmark.circle.fill" : "lock.shield").font(.system(size: 30)).foregroundStyle(wm.trusted ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility").font(.headline)
                    Text(wm.trusted ? String(localized: "Allowed. Thank you.") : String(localized: "Turn Panefold on in System Settings › Privacy & Security › Accessibility. This page updates by itself."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !wm.trusted {
                    Button(String(localized: "Allow…")) {
                        _ = AX.isTrusted(prompt: true)
                        SystemState.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            Toggle(String(localized: "Open Panefold at login"), isOn: $wm.prefs.openAtLogin)
            if !HotkeyBinder.shared.unavailable.isEmpty {
                Text("Some shortcuts are already used by another app. You can pick other keys in Settings › Keyboard.").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("The moves").font(.largeTitle.bold())
                Spacer()
                Picker("", selection: $keyboard) {
                    Text("Keyboard").tag(true)
                    Text("Mouse").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            let p = wm.prefs.shortcuts
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                card("square.grid.2x2", String(localized: "Automatic tiling"), String(localized: "Open an app: it takes a place."), nil)
                card("arrow.left.arrow.right", String(localized: "Swap"), keyboard ? String(localized: "\(p.prefix.modifiers.symbols) and an arrow") : String(localized: "Hold ⌘ and drag onto another window"), nil)
                card("rectangle.lefthalf.filled", String(localized: "Make it the big one"), keyboard ? (p.combo(.makePrimary)?.label ?? "") : String(localized: "Grip above the window › Primary"), nil)
                card("arrow.up.left.and.arrow.down.right", String(localized: "Focus mode"), keyboard ? (p.combo(.focusMode)?.label ?? "") : String(localized: "Grip above the window › Focus"), nil)
                card("square.3.layers.3d", String(localized: "Stacks"), keyboard ? String(localized: "Screen full? It stacks. \(p.combo(.nextInStack)?.label ?? "") switches.") : String(localized: "Click the orange marks above a window"), nil)
                card("eye.slash", String(localized: "No peek and Clean Space"), keyboard ? "\(p.combo(.noPeek)?.label ?? "")  ·  \(p.combo(.cleanSpace)?.label ?? "")" : String(localized: "In the menu bar panel"), nil)
                card("rectangle.on.rectangle", String(localized: "Window switcher"), keyboard ? (p.combo(.tabView)?.label ?? "") : String(localized: "Open it, then click a window"), nil)
                card("number", String(localized: "Windows per screen"), keyboard ? String(localized: "\(p.combo(.count1)?.modifiers.symbols ?? "")1–4") : String(localized: "Menu bar panel › Windows on this screen"), nil)
            }
            Spacer()
        }
    }

    private func card(_ symbol: String, _ title: String, _ how: String, _ unused: Void?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).frame(width: 34).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(how).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var makeItYours: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Make it yours").font(.largeTitle.bold())
            HStack(spacing: 12) {
                ForEach(LayoutKind.allCases, id: \.self) { kind in
                    Button { wm.prefs.layout = kind } label: {
                        VStack(spacing: 6) {
                            LayoutPicture(kind: kind, count: wm.prefs.windowsPerScreen, selected: wm.prefs.layout == kind).frame(width: 110, height: 68)
                            Text(WindowManager.name(of: kind)).font(.callout)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(wm.prefs.layout == kind ? Color.accentColor.opacity(0.14) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            SettingRow(title: String(localized: "Windows per screen")) {
                Picker("", selection: $wm.prefs.windowsPerScreen) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow(title: String(localized: "Highlight the active window")) {
                Picker("", selection: $wm.prefs.highlight) {
                    Text("None").tag(Highlight.none)
                    Text("Border").tag(Highlight.borderActive)
                    Text("Glow").tag(Highlight.glowActive)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow(title: String(localized: "When a screen is full")) {
                Picker("", selection: $wm.prefs.whenFull) {
                    Text("Stack").tag(FullScreenPolicy.stack)
                    Text("Float in the middle").tag(FullScreenPolicy.floatInMiddle)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Spacer()
        }
    }

    private var ready: some View {
        VStack(spacing: 20) {
            Image(nsImage: AppIcon.image(wm.prefs.iconStyle, size: 256)).resizable().frame(width: 110, height: 110)
            Text("Ready when you are").font(.largeTitle.bold())
            Text("Your windows move only when you press the button. After that, Panefold lives in the menu bar.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                wm.tidyEverything()
                close()
            } label: {
                Text("Tidy My Workspace").font(.title3.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(!wm.trusted)
            if !wm.trusted { Text("Allow Accessibility access first.").font(.caption).foregroundStyle(.orange) }
        }
    }
}
