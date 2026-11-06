#if DEBUG
import AppKit
import SwiftUI
import PanefoldCore

/// Debug builds only: renders interface screens to PNG for the README, then quits.
///
///     PANEFOLD_DEFAULTS_SUITE=dev.panefold.snapshot PANEFOLD_SNAPSHOT_DIR=docs .build/debug/Panefold
///
/// Add PANEFOLD_DARK=1 for dark mode. Uses its own preferences suite so your settings aren't touched.
@MainActor
enum Snapshot {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["PANEFOLD_SNAPSHOT_DIR"] else { return false }
        let dark = ProcessInfo.processInfo.environment["PANEFOLD_DARK"] == "1"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let suffix = dark ? "-dark" : ""
        let wm = WindowManager.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        render(OnboardingView(close: {}).environmentObject(wm), size: CGSize(width: 720, height: 540), to: "\(dir)/screenshot-onboarding\(suffix).png")
        let model = Windows.shared.settingsModel
        for page in [SettingsPage.overview, .layout, .keyboard] {
            model.page = page
            render(SettingsPageContent(model: model).environmentObject(wm), size: CGSize(width: 640, height: 600), to: "\(dir)/screenshot-\(page.rawValue)\(suffix).png")
        }
        render(AppIconView(), size: CGSize(width: 512, height: 512), to: "\(dir)/icon.png")
        NSApp.terminate(nil)
        return true
    }

    private static func render<V: View>(_ view: V, size: CGSize, to path: String) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private struct AppIconView: View {
    var body: some View { Image(nsImage: AppIcon.image(.panefold, size: 512)) }
}
#endif
