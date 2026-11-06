import AppKit
import SwiftUI
import PanefoldCore
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, general, layout, docks, highlight, focus, mouse, keyboard, apps, setups, activity, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "What Panefold can do")
        case .general: String(localized: "General")
        case .layout: String(localized: "Layout")
        case .docks: String(localized: "Docks and bars")
        case .highlight: String(localized: "Highlight")
        case .focus: String(localized: "Focus")
        case .mouse: String(localized: "Mouse")
        case .keyboard: String(localized: "Keyboard")
        case .apps: String(localized: "Apps")
        case .setups: String(localized: "Setups")
        case .activity: String(localized: "Activity")
        case .about: String(localized: "About")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: String(localized: "Every feature, with its shortcut")
        case .general: String(localized: "Language, light or dark, open at login")
        case .layout: String(localized: "Windows per screen, main size, spacing")
        case .docks: String(localized: "Room for another app's dock or bar")
        case .highlight: String(localized: "Borders and glow")
        case .focus: String(localized: "No peek mode, Clean Space, focus mode")
        case .mouse: String(localized: "Quick actions, hover focus")
        case .keyboard: String(localized: "Change any shortcut, or the prefix")
        case .apps: String(localized: "Apps left out, always floated, or that can't shrink")
        case .setups: String(localized: "Saved arrangements of apps")
        case .activity: String(localized: "Windows tiled and time saved")
        case .about: String(localized: "Version, updates, reporting a problem")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .general: "gearshape"
        case .layout: "square.grid.2x2"
        case .docks: "dock.rectangle"
        case .highlight: "rectangle.dashed"
        case .focus: "eye"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .apps: "app.badge"
        case .setups: "square.stack.3d.up"
        case .activity: "chart.bar"
        case .about: "info.circle"
        }
    }

    /// Words a search can find this page by.
    var keywords: String {
        switch self {
        case .overview: "features demo"
        case .general: "language appearance light dark login startup icon tour accessibility updates"
        case .layout: "grid columns rows side main size windows per screen new windows full stack float gap space"
        case .docks: "dock bar edge inset margin dockset"
        case .highlight: "border glow color thickness"
        case .focus: "no peek dim blur clean space background focus mode zoom present share"
        case .mouse: "quick actions hover bar grip activate hover"
        case .keyboard: "shortcut prefix keys hotkey cheat sheet"
        case .apps: "exclude float rule dialog minimum size shrink"
        case .setups: "setup apps workspace open"
        case .activity: "stats count time saved"
        case .about: "version update report problem feature feedback"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .overview
    @Published var search = ""
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @EnvironmentObject var wm: WindowManager

    private var pages: [SettingsPage] {
        let q = model.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsPage.allCases }
        return SettingsPage.allCases.filter { ($0.title + " " + $0.subtitle + " " + $0.keywords).lowercased().contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(pages, selection: Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })) { page in
                VStack(alignment: .leading, spacing: 1) {
                    Label(page.title, systemImage: page.symbol)
                    Text(page.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 26)
                }
                .tag(page)
                .padding(.vertical, 2)
            }
            .searchable(text: $model.search, placement: .sidebar, prompt: String(localized: "Search settings"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            SettingsPageContent(model: model)
        }
    }
}

/// One settings page, scrollable. Also used on its own for README screenshots.
struct SettingsPageContent: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.page.title).font(.largeTitle.bold()).padding(.bottom, 16)
                detail
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.page {
        case .overview: OverviewPage(model: model)
        case .general: GeneralPage()
        case .layout: LayoutPage()
        case .docks: DocksPage()
        case .highlight: HighlightPage()
        case .focus: FocusPage()
        case .mouse: MousePage()
        case .keyboard: KeyboardPage()
        case .apps: AppsPage()
        case .setups: SetupsPage()
        case .activity: ActivityPage()
        case .about: AboutPage()
        }
    }
}

/// A titled group of settings rows.
struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        }
        .padding(.bottom, 22)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            control
        }
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    @ObservedObject var model: SettingsModel
    @EnvironmentObject var wm: WindowManager

    struct Feature: Identifiable {
        let id = UUID()
        let symbol: String, title: String, line: String
        let action: ShortcutAction?
        let page: SettingsPage
    }

    var groups: [(String, [Feature])] {
        [
            (String(localized: "Arrange"), [
                Feature(symbol: "square.grid.2x2", title: String(localized: "Automatic tiling"), line: String(localized: "Every window takes a place the moment it opens."), action: .toggleTiling, page: .layout),
                Feature(symbol: "arrow.left.arrow.right", title: String(localized: "Swap windows"), line: String(localized: "⌘-drag one onto another, or use the arrows."), action: .swapRight, page: .mouse),
                Feature(symbol: "rectangle.lefthalf.filled", title: String(localized: "Make primary"), line: String(localized: "Give the active window the big tile."), action: .makePrimary, page: .layout),
                Feature(symbol: "square.3.layers.3d", title: String(localized: "Stacks"), line: String(localized: "A full screen stacks new windows in your tile."), action: .nextInStack, page: .layout),
                Feature(symbol: "arrow.up.left.and.arrow.down.right", title: String(localized: "Resize"), line: String(localized: "Drag the edge between windows, or step it."), action: .grow, page: .layout),
                Feature(symbol: "macwindow.on.rectangle", title: String(localized: "Float"), line: String(localized: "Take a window out of the layout for a while."), action: .float, page: .apps),
                Feature(symbol: "square.stack.3d.up", title: String(localized: "Setups"), line: String(localized: "Open your work apps, arranged, in one click."), action: nil, page: .setups),
            ]),
            (String(localized: "Focus"), [
                Feature(symbol: "arrow.up.left.and.arrow.down.right.circle", title: String(localized: "Focus mode"), line: String(localized: "One window fills the screen; again to go back."), action: .focusMode, page: .focus),
                Feature(symbol: "eye.slash", title: String(localized: "No peek mode"), line: String(localized: "Everything but your window fades."), action: .noPeek, page: .focus),
                Feature(symbol: "rectangle.inset.filled", title: String(localized: "Clean Space"), line: String(localized: "Show one window on a plain screen."), action: .cleanSpace, page: .focus),
                Feature(symbol: "rectangle.dashed", title: String(localized: "Borders and glow"), line: String(localized: "See the active window at a glance."), action: nil, page: .highlight),
            ]),
            (String(localized: "Get around"), [
                Feature(symbol: "rectangle.on.rectangle", title: String(localized: "Window switcher"), line: String(localized: "Every window by screen. Hold ⌥, press ⇥."), action: .tabView, page: .keyboard),
                Feature(symbol: "arrow.right.square", title: String(localized: "Next window"), line: String(localized: "Hop between tiled windows."), action: .nextWindow, page: .keyboard),
                Feature(symbol: "cursorarrow.rays", title: String(localized: "Quick actions"), line: String(localized: "Rest on the grip above a window."), action: nil, page: .mouse),
                Feature(symbol: "keyboard", title: String(localized: "Cheat sheet"), line: String(localized: "Every shortcut, over your screen."), action: .cheatSheet, page: .keyboard),
            ]),
        ]
    }

    var body: some View {
        ForEach(groups, id: \.0) { title, features in
            Section2(title: title) {
                ForEach(features) { f in
                    Button { model.page = f.page } label: {
                        HStack(spacing: 12) {
                            Image(systemName: f.symbol).font(.title3).frame(width: 28).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.body.weight(.medium))
                                Text(f.line).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let a = f.action, let combo = wm.prefs.shortcuts.combo(a) { KeyCaps(text: combo.label) }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @EnvironmentObject var wm: WindowManager
    @ObservedObject private var updater = Updater.shared
    @AppStorage("PanefoldLanguage") private var language = "system"

    static let languages: [(String, String)] = [("system", String(localized: "System")), ("en", "English"), ("es", "Español"),
                                                ("ja", "日本語"), ("ko", "한국어"), ("zh-Hans", "简体中文"), ("id", "Bahasa Indonesia")]

    var body: some View {
        Section2(title: String(localized: "Tiling")) {
            SettingRow(title: String(localized: "Automatic tiling"), detail: String(localized: "Arrange windows as they open and close. ⌃⌥T")) {
                Toggle("", isOn: $wm.prefs.tilingEnabled).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: String(localized: "Accessibility access"), detail: wm.trusted ? String(localized: "Allowed") : String(localized: "Panefold can't arrange windows without it.")) {
                if wm.trusted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(String(localized: "Grant Access…")) {
                        _ = AX.isTrusted(prompt: true)
                        SystemState.openAccessibilitySettings()
                    }
                }
            }
        }
        Section2(title: String(localized: "Startup")) {
            SettingRow(title: String(localized: "Open at login")) {
                Toggle("", isOn: $wm.prefs.openAtLogin).toggleStyle(.switch).labelsHidden()
            }
            Button(String(localized: "Open Login Items…")) { SystemState.openLoginItems() }.buttonStyle(.link)
            SettingRow(title: String(localized: "Welcome tour")) {
                Button(String(localized: "Open Tour")) { Windows.shared.showOnboarding() }
            }
        }
        Section2(title: String(localized: "Appearance")) {
            SettingRow(title: String(localized: "Light or dark"), detail: String(localized: "Settings, the menu bar panel and notices. The switcher and the hover bar stay dark.")) {
                Picker("", selection: $wm.prefs.appearance) {
                    Text("Match the Mac").tag(AppearanceChoice.system)
                    Text("Light").tag(AppearanceChoice.light)
                    Text("Dark").tag(AppearanceChoice.dark)
                }
                .labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("App icon")
                HStack(spacing: 10) {
                    ForEach(IconStyle.allCases, id: \.self) { style in
                        Button { wm.prefs.iconStyle = style } label: {
                            Image(nsImage: AppIcon.image(style, size: 96)).resizable().frame(width: 48, height: 48)
                                .padding(3)
                                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(wm.prefs.iconStyle == style ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain).help(style.rawValue.capitalized)
                    }
                }
            }
            SettingRow(title: String(localized: "Language"), detail: String(localized: "Takes effect after a restart.")) {
                HStack {
                    Picker("", selection: $language) {
                        ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: language) {
                        if language == "system" {
                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                        } else {
                            UserDefaults.standard.set([language], forKey: "AppleLanguages")
                        }
                    }
                    Button(String(localized: "Restart Now")) { Self.relaunch() }
                }
            }
        }
        Section2(title: String(localized: "Updates")) {
            SettingRow(title: String(localized: "Check for updates automatically"), detail: String(localized: "Once a day, from GitHub. Nothing about your Mac is sent.")) {
                Toggle("", isOn: $wm.prefs.checkForUpdates).toggleStyle(.switch).labelsHidden()
            }
            HStack {
                Button(String(localized: "Check Now")) { updater.check() }.disabled(updater.checking)
                if let r = updater.lastResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                if let a = updater.available { Button(String(localized: "Download")) { NSWorkspace.shared.open(a.url) } }
            }
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Layout

private struct LayoutPage: View {
    @EnvironmentObject var wm: WindowManager

    var body: some View {
        Section2(title: String(localized: "Shape")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Layout")
                HStack(spacing: 12) {
                    ForEach(LayoutKind.allCases, id: \.self) { kind in
                        Button { wm.prefs.layout = kind } label: {
                            VStack(spacing: 6) {
                                LayoutPicture(kind: kind, count: 3, mainSize: wm.prefs.mainSize, selected: wm.prefs.layout == kind)
                                    .frame(width: 84, height: 52)
                                Text(WindowManager.name(of: kind)).font(.caption)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(wm.prefs.layout == kind ? Color.accentColor.opacity(0.12) : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(layoutLine).font(.caption).foregroundStyle(.secondary)
            }
            SettingRow(title: String(localized: "Main window size"), detail: String(localized: "How much room the main window starts with, in every layout.")) {
                Picker("", selection: $wm.prefs.mainSize) {
                    Text("Half").tag(MainSize.half)
                    Text("60%").tag(MainSize.sixty)
                    Text("Two-thirds").tag(MainSize.twoThirds)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow(title: String(localized: "Windows per screen"), detail: String(localized: "Where every screen starts. A screen you pick a count for in the menu keeps its own.")) {
                Picker("", selection: $wm.prefs.windowsPerScreen) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        Section2(title: String(localized: "Opening more windows")) {
            SettingRow(title: String(localized: "New windows"), detail: String(localized: "Main tile: the new window takes the big tile and the others move down one place.")) {
                Picker("", selection: $wm.prefs.newWindows) {
                    Text("Next free tile").tag(NewWindowPlacement.nextFreeTile)
                    Text("Main tile").tag(NewWindowPlacement.mainTile)
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(title: String(localized: "When a screen is full"), detail: String(localized: "Stack: the new window joins the tile you're in and the old one waits behind it.")) {
                Picker("", selection: $wm.prefs.whenFull) {
                    Text("Stack in the active tile").tag(FullScreenPolicy.stack)
                    Text("Float in the middle").tag(FullScreenPolicy.floatInMiddle)
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(title: String(localized: "Moving into a full screen"), detail: String(localized: "What ⌃⌥ and an arrow, or Next screen, does when the other screen is full.")) {
                Picker("", selection: $wm.prefs.movingIntoFull) {
                    Text("Swap places").tag(MoveIntoFullScreen.swap)
                    Text("Stack on top").tag(MoveIntoFullScreen.stack)
                }
                .labelsHidden().fixedSize()
            }
        }
        Section2(title: String(localized: "Spacing")) {
            SettingRow(title: String(localized: "Space between windows"), detail: String(localized: "Also used around the edges of the screen.")) {
                HStack {
                    Slider(value: $wm.prefs.gap, in: Preferences.gapRange, step: 1).frame(width: 180)
                    Text("\(Int(wm.prefs.gap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private var layoutLine: String {
        switch wm.prefs.layout {
        case .grid: String(localized: "One big window, the rest folded beside it, and 2×2 for four.")
        case .columns: String(localized: "Every window side by side, full height.")
        case .rows: String(localized: "Every window full width, one above the other. Good for logs and terminals.")
        case .side: String(localized: "One big window, the others in one column beside it. On an ultrawide, two big ones.")
        }
    }
}

// MARK: - Docks and bars

private struct DocksPage: View {
    @EnvironmentObject var wm: WindowManager
    @State private var screenID = ""
    @State private var strip: OverlayPanel?

    var body: some View {
        let displays = wm.screens.map(\.display)
        Section2(title: String(localized: "Keep space free")) {
            Text("macOS keeps windows clear of the menu bar and its own Dock, but not of a dock or bar from another app. Keep room for one here.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle(String(localized: "Same on every screen"), isOn: $wm.prefs.sameInsetsEverywhere)
            if !wm.prefs.sameInsetsEverywhere, displays.count > 1 {
                Picker(String(localized: "Screen"), selection: $screenID) {
                    ForEach(displays) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
            }
            ForEach(["top", "bottom", "left", "right"], id: \.self) { edge in
                SettingRow(title: Self.edgeName(edge)) {
                    HStack {
                        Slider(value: binding(edge), in: EdgeInsets.range, step: 2) { editing in
                            editing ? showStrip(edge) : hideStrip()
                        }
                        .frame(width: 220)
                        Text("\(Int(binding(edge).wrappedValue)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .onAppear { if screenID.isEmpty { screenID = displays.first?.id ?? "" } }
    }

    static func edgeName(_ e: String) -> String {
        switch e {
        case "top": String(localized: "Top")
        case "bottom": String(localized: "Bottom")
        case "left": String(localized: "Left")
        default: String(localized: "Right")
        }
    }

    private func binding(_ edge: String) -> Binding<CGFloat> {
        Binding {
            let i = wm.prefs.sameInsetsEverywhere ? wm.prefs.sharedInsets : wm.prefs.insets(for: screenID)
            switch edge {
            case "top": return i.top
            case "bottom": return i.bottom
            case "left": return i.left
            default: return i.right
            }
        } set: { v in
            var i = wm.prefs.sameInsetsEverywhere ? wm.prefs.sharedInsets : wm.prefs.insets(for: screenID)
            switch edge {
            case "top": i.top = v
            case "bottom": i.bottom = v
            case "left": i.left = v
            default: i.right = v
            }
            if wm.prefs.sameInsetsEverywhere { wm.prefs.sharedInsets = i } else { wm.prefs.insetsByScreen[screenID] = i }
            showStrip(edge)
        }
    }

    /// A blue strip marks the space kept free while you drag.
    private func showStrip(_ edge: String) {
        guard let d = wm.screens.map(\.display).first(where: { $0.id == screenID }) ?? wm.screens.first?.display else { return }
        let i = wm.prefs.sameInsetsEverywhere ? wm.prefs.sharedInsets : wm.prefs.insets(for: d.id)
        let v = d.visible
        let r: CGRect
        switch edge {
        case "top": r = CGRect(x: v.minX, y: v.minY, width: v.width, height: max(2, i.top))
        case "bottom": r = CGRect(x: v.minX, y: v.maxY - max(2, i.bottom), width: v.width, height: max(2, i.bottom))
        case "left": r = CGRect(x: v.minX, y: v.minY, width: max(2, i.left), height: v.height)
        default: r = CGRect(x: v.maxX - max(2, i.right), y: v.minY, width: max(2, i.right), height: v.height)
        }
        let panel = strip ?? {
            let p = OverlayPanel(level: .floating)
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
            p.contentView = view
            DispatchQueue.main.async { strip = p }
            return p
        }()
        panel.place(r)
        panel.orderFront(nil)
    }

    private func hideStrip() { strip?.orderOut(nil) }
}

// MARK: - Highlight

private struct HighlightPage: View {
    @EnvironmentObject var wm: WindowManager
    @State private var custom = Color.blue

    var body: some View {
        Section2(title: String(localized: "Highlight")) {
            Picker("", selection: $wm.prefs.highlight) {
                Text("None").tag(Highlight.none)
                Text("Border on active").tag(Highlight.borderActive)
                Text("Border on all").tag(Highlight.borderAll)
                Text("Glow on active").tag(Highlight.glowActive)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Text("Borders and the glow sit in the space between windows, so they never cover what's inside.").font(.caption).foregroundStyle(.secondary)
        }
        Section2(title: String(localized: "Color and thickness")) {
            HStack(spacing: 8) {
                swatch(.accent, Color.accentColor, String(localized: "Accent color"))
                ForEach(HighlightColor.presets, id: \.name) { p in
                    swatch(.preset(p.name), Color(nsColor: NSColor(rgb: p.rgb)), p.name)
                }
                ColorPicker("", selection: Binding(get: { custom }, set: { c in
                    custom = c
                    if let rgb = NSColor(c).usingColorSpace(.sRGB) {
                        wm.prefs.highlightColor = .custom(UInt32(rgb.redComponent * 255) << 16 | UInt32(rgb.greenComponent * 255) << 8 | UInt32(rgb.blueComponent * 255))
                    }
                }), supportsOpacity: false).labelsHidden()
            }
            SettingRow(title: String(localized: "Border thickness"), detail: String(localized: "The space between windows grows to fit.")) {
                HStack {
                    Slider(value: $wm.prefs.borderWidth, in: Preferences.borderRange, step: 1).frame(width: 160)
                    Text("\(Int(wm.prefs.borderWidth)) pt").monospacedDigit()
                }
            }
        }
    }

    private func swatch(_ value: HighlightColor, _ color: Color, _ name: String) -> some View {
        Button { wm.prefs.highlightColor = value } label: {
            Circle().fill(color).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.primary.opacity(wm.prefs.highlightColor == value ? 0.9 : 0), lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain).help(name)
    }
}

// MARK: - Focus

private struct FocusPage: View {
    @EnvironmentObject var wm: WindowManager

    var body: some View {
        Section2(title: String(localized: "No peek mode")) {
            SettingRow(title: String(localized: "No peek mode"), detail: String(localized: "Every window except the one you're in fades back. ⌃⌥D")) {
                Toggle("", isOn: $wm.prefs.noPeek).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: String(localized: "Dim amount")) {
                HStack {
                    Slider(value: $wm.prefs.dimAmount, in: Preferences.dimRange).frame(width: 180)
                    Text("\(Int(wm.prefs.dimAmount * 100))%").monospacedDigit().frame(width: 40)
                }
            }
            SettingRow(title: String(localized: "Blur other windows"), detail: String(localized: "So what's in them can't be read, even at a light dim.")) {
                Toggle("", isOn: $wm.prefs.blurOthers).toggleStyle(.switch).labelsHidden()
            }
        }
        Section2(title: String(localized: "Clean Space")) {
            Text("The window you're showing fills the screen on a plain background. Nothing is hidden, moved or closed. ⌃⌥P")
                .font(.callout).foregroundStyle(.secondary)
            Picker(String(localized: "Background"), selection: $wm.prefs.cleanBackground) {
                Text("Graphite").tag(CleanBackground.graphite)
                Text("Mist").tag(CleanBackground.mist)
                Text("Stone").tag(CleanBackground.stone)
            }
            .pickerStyle(.segmented).fixedSize()
        }
        Section2(title: String(localized: "Focus mode")) {
            SettingRow(title: String(localized: "Fill the screen with the active window, or put it back"), detail: String(localized: "Ends when you switch windows, open one, or change the layout.")) {
                KeyCaps(text: wm.prefs.shortcuts.combo(.focusMode)?.label ?? String(localized: "Off"))
            }
        }
    }
}

// MARK: - Mouse

private struct MousePage: View {
    @EnvironmentObject var wm: WindowManager

    var body: some View {
        Section2(title: String(localized: "Mouse")) {
            SettingRow(title: String(localized: "Quick actions above windows"), detail: String(localized: "Rest the pointer on the grip above a window for Primary, Focus, Next screen and Float.")) {
                Toggle("", isOn: $wm.prefs.quickActions).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: String(localized: "Activate windows on hover"), detail: String(localized: "Point at a window to make it active. It waits a moment and ignores the pointer while you type.")) {
                Toggle("", isOn: $wm.prefs.hoverFocus).toggleStyle(.switch).labelsHidden()
                    .onChange(of: wm.prefs.hoverFocus) { MouseController.shared.updateHoverFocus() }
            }
        }
        Section2(title: String(localized: "Always available")) {
            Label("Hold ⌘ and drag a window onto another to swap them.", systemImage: "arrow.left.arrow.right")
            Label("Hold ⌥⌘ and drag onto a window to add it to that tile's stack.", systemImage: "square.3.layers.3d")
            Label("Drag the edge between two windows to resize; the neighbors make room.", systemImage: "arrow.left.and.right")
            Label("Drag a window onto another screen to move it there.", systemImage: "rectangle.portrait.and.arrow.right")
        }
    }
}

// MARK: - Apps

private struct AppsPage: View {
    @EnvironmentObject var wm: WindowManager

    var body: some View {
        Section2(title: String(localized: "Don't tile these apps")) {
            ForEach(wm.prefs.exclusions.entries, id: \.bundleID) { e in
                HStack {
                    appIcon(e.bundleID)
                    Text(e.name)
                    if e.isDefault { Text("Default").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).background(Color.primary.opacity(0.07), in: Capsule()) }
                    Spacer()
                    Button(String(localized: "Remove")) { wm.prefs.exclusions.include(e.bundleID) }.buttonStyle(.link)
                }
            }
            Button(String(localized: "Choose from Applications…"), action: chooseApp)
        }
        Section2(title: String(localized: "Always float these windows")) {
            if wm.prefs.floatRules.isEmpty {
                Text("Press ⌃⌥⇧F on a dialog that gets tiled, like a Commit dialog, to always float it.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(wm.prefs.floatRules) { rule in
                HStack {
                    appIcon(rule.bundleID)
                    Text(rule.appName)
                    Text("“\(rule.prefix)…”").foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Remove")) { wm.prefs.floatRules.removeAll { $0 == rule } }.buttonStyle(.link)
                }
            }
        }
        Section2(title: String(localized: "Apps that can't shrink")) {
            if wm.learner.learned.isEmpty {
                Text("None yet. Panefold learns an app's smallest size when it refuses to get smaller.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(wm.learner.learned.keys.sorted(), id: \.self) { id in
                let size = wm.learner.learned[id] ?? .zero
                HStack {
                    appIcon(id)
                    Text(Self.name(id))
                    Text("\(size.width > 0 ? "\(Int(size.width))" : String(localized: "Any")) × \(size.height > 0 ? "\(Int(size.height))" : String(localized: "Any"))")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Forget")) { wm.learner.forget(id) }.buttonStyle(.link)
                    Button(String(localized: "Never Learn")) { wm.learner.setNeverLearn(id, true) }.buttonStyle(.link)
                }
            }
            if !wm.learner.neverLearn.isEmpty {
                Text("Never learned for").font(.caption).foregroundStyle(.secondary)
                ForEach(wm.learner.neverLearn.sorted(), id: \.self) { id in
                    HStack {
                        Text(Self.name(id))
                        Spacer()
                        Button(String(localized: "Learn Again")) { wm.learner.setNeverLearn(id, false) }.buttonStyle(.link)
                    }
                }
            }
            if !wm.learner.learned.isEmpty { Button(String(localized: "Forget All")) { wm.learner.forgetAll() } }
            if !wm.prefs.roomCardMuted.isEmpty {
                Divider()
                Text("“Needs more room” is off for").font(.caption).foregroundStyle(.secondary)
                ForEach(wm.prefs.roomCardMuted.sorted(), id: \.self) { id in
                    HStack {
                        Text(Self.name(id))
                        Spacer()
                        Button(String(localized: "Show Again")) { wm.prefs.roomCardMuted.remove(id) }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    static func name(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    private func appIcon(_ bundleID: String) -> some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app").resizable()
            }
        }
        .frame(width: 20, height: 20)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            wm.prefs.exclusions.exclude(id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }
}

// MARK: - Setups

private struct SetupsPage: View {
    @EnvironmentObject var wm: WindowManager
    @ObservedObject private var runner = SetupRunner.shared
    @State private var newName = ""
    @State private var recording: UUID?

    var body: some View {
        Section2(title: String(localized: "Setups")) {
            Text("A setup remembers which app sits in which tile, on every screen. Opening one opens its apps and hides the others; nothing is quit.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(String(localized: "Name, like “Coding”"), text: $newName).textFieldStyle(.roundedBorder).onSubmit(save)
                Button(String(localized: "Save this arrangement"), action: save).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        ForEach($wm.setups) { $setup in
            Section2(title: setup.name) {
                HStack {
                    TextField(String(localized: "Name"), text: $setup.name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    if wm.activeSetupID == setup.id {
                        Text(runner.isOnScreen(setup) ? String(localized: "ON SCREEN") : String(localized: "CHANGED"))
                            .font(.caption.bold()).foregroundStyle(runner.isOnScreen(setup) ? .green : .orange)
                    }
                    Spacer()
                    Button(String(localized: "Open")) { runner.open(setup.id) }
                    Menu {
                        Button(String(localized: "Update from What's on Screen")) { runner.update(setup.id) }
                        Button(String(localized: "Remove Shortcut")) { setup.shortcut = nil }.disabled(setup.shortcut == nil)
                        Divider()
                        Button(String(localized: "Delete"), role: .destructive) { wm.setups.removeAll { $0.id == setup.id } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                SettingRow(title: String(localized: "Shortcut")) {
                    ShortcutField(combo: setup.shortcut, recording: Binding(get: { recording == setup.id }, set: { recording = $0 ? setup.id : nil })) { combo in
                        setup.shortcut = combo
                    }
                }
                ForEach(setup.screens, id: \.screenID) { screen in
                    HStack(alignment: .top, spacing: 12) {
                        LayoutPicture(kind: screen.layout, count: max(1, screen.tiles.count)).frame(width: 60, height: 38)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(screen.screenName) · \(WindowManager.name(of: screen.layout))").font(.callout.weight(.medium))
                            Text(screen.apps.map(AppsPage.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        runner.save(name: name)
        newName = ""
    }
}

// MARK: - Activity

private struct ActivityPage: View {
    @EnvironmentObject var wm: WindowManager

    var body: some View {
        let week = wm.activity.week()
        let saved = ActivityLog.timeSaved(week)
        let fav = ActivityLog.favorites(week, suggestions: ["focusMode", "swapRight", "makePrimary", "nextInStack", "tabView", "noPeek", "grow"])
        Section2(title: String(localized: "This week")) {
            HStack(spacing: 24) {
                stat("\(week.placed)", String(localized: "windows placed"))
                stat(Self.duration(saved), String(localized: "saved, roughly"))
            }
            let total = max(1, week.keyboardTotal + week.mouseTotal)
            VStack(alignment: .leading, spacing: 6) {
                Text("Keyboard or mouse").font(.callout)
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Rectangle().fill(Color.accentColor).frame(width: geo.size.width * week.keyboardTotal / total)
                        Rectangle().fill(Color.orange)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack {
                    Label("Keyboard \(Int(week.keyboardTotal))", systemImage: "keyboard").foregroundStyle(Color.accentColor)
                    Spacer()
                    Label("Mouse \(Int(week.mouseTotal))", systemImage: "computermouse").foregroundStyle(.orange)
                }
                .font(.caption)
            }
            if let most = fav.mostUsed.flatMap(ShortcutAction.init(rawValue:)) {
                SettingRow(title: String(localized: "Used most"), detail: ShortcutText.name(most)) {
                    KeyCaps(text: wm.prefs.shortcuts.combo(most)?.label ?? "")
                }
            }
            if let next = fav.tryNext.flatMap(ShortcutAction.init(rawValue:)) {
                SettingRow(title: String(localized: "Try next"), detail: ShortcutText.name(next)) {
                    KeyCaps(text: wm.prefs.shortcuts.combo(next)?.label ?? "")
                }
            }
        }
        Section2(title: String(localized: "Counting")) {
            SettingRow(title: String(localized: "Count activity"), detail: String(localized: "Numbers only, kept on this Mac. Never window titles or app names.")) {
                Toggle("", isOn: $wm.prefs.countActivity).toggleStyle(.switch).labelsHidden()
            }
            Button(String(localized: "Reset Activity")) { wm.activity = ActivityLog() }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        return f.string(from: max(t, 0)) ?? "0m"
    }
}

// MARK: - About

private struct AboutPage: View {
    @ObservedObject private var updater = Updater.shared
    @EnvironmentObject var wm: WindowManager
    @State private var message = ""
    @State private var diagnostics = true
    @State private var showing = false

    var body: some View {
        Section2(title: String(localized: "Panefold")) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image(wm.prefs.iconStyle, size: 128)).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Panefold \(SystemState.version)").font(.title3.bold())
                    Text("Automatic window tiling for macOS. Free and open source, MIT License.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(String(localized: "Check for Updates…")) { updater.check() }
                        Link(String(localized: "Website and source"), destination: URL(string: "https://github.com/\(Updater.repository)")!)
                    }
                    if let r = updater.lastResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        Section2(title: String(localized: "Report a problem or suggest a feature")) {
            TextEditor(text: $message).frame(height: 90).font(.callout)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            Toggle(String(localized: "Include diagnostics"), isOn: $diagnostics)
            Text("Apps appear as letters (App A, App B). Window titles are never included. Nothing is sent by Panefold: the report is copied, and a new GitHub issue opens for you to paste it into.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Show what's included")) { showing.toggle() }
                Spacer()
                Button(String(localized: "Copy Report")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Feedback.report(message: message, diagnostics: diagnostics), forType: .string)
                }
                Button(String(localized: "Report a Problem…")) {
                    Feedback.openIssue(title: String(localized: "Problem: ") + message.prefix(60), report: Feedback.report(message: message, diagnostics: diagnostics))
                }
                Button(String(localized: "Suggest a Feature…")) {
                    Feedback.openIssue(title: String(localized: "Idea: ") + message.prefix(60), report: Feedback.report(message: message, diagnostics: false))
                }
            }
            if showing {
                ScrollView {
                    Text(Feedback.report(message: message, diagnostics: diagnostics)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            }
        }
    }
}
