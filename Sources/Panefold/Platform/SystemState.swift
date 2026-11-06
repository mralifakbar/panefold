import AppKit
import Carbon.HIToolbox
import ServiceManagement
import PanefoldCore

enum SystemState {
    /// Stage Manager arranges windows its own way, so tiling pauses while it's on.
    static var stageManagerOn: Bool {
        CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
    }

    /// A password field or secure terminal is blocking shortcuts for every app.
    static var secureInputOn: Bool { IsSecureEventInputEnabled() }

    /// macOS's own enabled shortcuts.
    static func systemShortcuts() -> Set<KeyCombo> {
        guard let dict = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] else { return [] }
        return SystemShortcuts.parse(dict)
    }

    static var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.info("Login item: \(error.localizedDescription)")
        }
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    static var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.hasPrefix("arm64")
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var macOS: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

/// A small log kept in memory (for reports) and printed in debug builds. Never holds window titles.
enum Log {
    private static var lines: [(Date, String)] = []
    private static let lock = NSLock()

    static func info(_ message: String) {
        lock.lock()
        lines.append((Date(), message))
        let cutoff = Date().addingTimeInterval(-3600)
        lines.removeAll { $0.0 < cutoff }
        lock.unlock()
        #if DEBUG
        print("[Panefold] \(message)")
        #endif
    }

    static var lastHour: String {
        lock.lock()
        defer { lock.unlock() }
        let f = ISO8601DateFormatter()
        return lines.map { "\(f.string(from: $0.0)) \($0.1)" }.joined(separator: "\n")
    }
}
