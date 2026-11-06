import AppKit
import SwiftUI
import PanefoldCore

@main
struct PanefoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var wm = WindowManager.shared
    @StateObject private var icon = MenuBarIcon.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(wm)
        } label: {
            Image(nsImage: icon.image)
                .accessibilityLabel("Panefold")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            #if DEBUG
            if Snapshot.runIfRequested() { return }
            #endif
            let wm = WindowManager.shared
            if wm.prefs.iconStyle != .panefold { AppIcon.apply(wm.prefs.iconStyle) }
            wm.start()
            MouseController.shared.start()
            if !wm.prefs.onboardingDone || !wm.trusted {
                Windows.shared.showOnboarding()
            }
            Updater.shared.checkIfDue()
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                MainActor.assumeIsolated { Updater.shared.checkIfDue() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Windows.shared.showSettings() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Settings and the welcome tour, as ordinary windows. A menu bar app brings itself forward to show them.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    private var settings: NSWindow?
    private var onboarding: NSWindow?
    let settingsModel = SettingsModel()

    func showSettings(page: SettingsPage? = nil) {
        if let page { settingsModel.page = page }
        let window = settings ?? {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = String(localized: "Panefold Settings")
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: SettingsView(model: settingsModel).environmentObject(WindowManager.shared))
            w.setContentSize(CGSize(width: 820, height: 600))
            w.minSize = CGSize(width: 720, height: 480)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("PanefoldSettings")
            w.delegate = self
            settings = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        let window = onboarding ?? {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in self?.onboarding?.close() }
                .environmentObject(WindowManager.shared))
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            onboarding = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settings {
            // Recording a shortcut pauses ours; closing Settings must never leave them paused.
            HotkeyBinder.shared.paused = false
        }
    }
}
