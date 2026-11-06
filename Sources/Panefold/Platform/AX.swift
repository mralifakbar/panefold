import AppKit
import ApplicationServices
import PanefoldCore

/// Private but stable since macOS 10.x, and used by every window manager: the window number behind an AX window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    /// Asks macOS whether we may control other apps' windows, optionally showing its prompt.
    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let e = AXUIElementCreateApplication(pid)
        // A frozen app must never freeze us.
        AXUIElementSetMessagingTimeout(e, 0.4)
        return e
    }

    static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.3)
        return e
    }()

    static func element(at point: CGPoint) -> AXUIElement? {
        var e: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &e) == .success else { return nil }
        return e
    }
}

extension AXUIElement {
    func value<T>(_ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &raw) == .success, let raw else { return nil }
        return raw as? T
    }

    private func axValue(_ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }

    var position: CGPoint? {
        var p = CGPoint.zero
        guard let v = axValue(kAXPositionAttribute), AXValueGetValue(v, .cgPoint, &p) else { return nil }
        return p
    }

    var size: CGSize? {
        var s = CGSize.zero
        guard let v = axValue(kAXSizeAttribute), AXValueGetValue(v, .cgSize, &s) else { return nil }
        return s
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    func setPosition(_ p: CGPoint) -> Bool {
        var v = p
        guard let value = AXValueCreate(.cgPoint, &v) else { return false }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ s: CGSize) -> Bool {
        var v = s
        guard let value = AXValueCreate(.cgSize, &v) else { return false }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, value) == .success
    }

    /// Moves and resizes. Size, position, size again: an app that clamps a size to its current screen
    /// gets the right answer whichever way the window travels.
    func setFrame(_ r: CGRect) {
        setSize(r.size)
        setPosition(r.origin)
        setSize(r.size)
    }

    var windowID: WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var role: String? { value(kAXRoleAttribute) }
    var subrole: String? { value(kAXSubroleAttribute) }
    var title: String? { value(kAXTitleAttribute) }
    var isMinimized: Bool { value(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { value("AXFullScreen") ?? false }
    var windows: [AXUIElement] { value(kAXWindowsAttribute) ?? [] }
    var focusedWindow: AXUIElement? { value(kAXFocusedWindowAttribute) }
    var parent: AXUIElement? { value(kAXParentAttribute) }
    var pid: pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(self, &p) == .success ? p : nil
    }

    var isSizeSettable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    func setMinimized(_ on: Bool) {
        AXUIElementSetAttributeValue(self, kAXMinimizedAttribute as CFString, on as CFBoolean)
    }

    func raise() {
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(self, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Presses the window's own close button, so its app asks about unsaved work. False if it has none.
    @discardableResult
    func pressClose() -> Bool {
        guard let button: AXUIElement = value(kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// The window an element belongs to.
    var containingWindow: AXUIElement? {
        if role == kAXWindowRole { return self }
        if let w: AXUIElement = value(kAXWindowAttribute) { return w }
        var e = parent
        for _ in 0..<12 {
            guard let current = e else { return nil }
            if current.role == kAXWindowRole { return current }
            e = current.parent
        }
        return nil
    }
}

/// Watches one app's windows and reports changes on the main thread.
final class AppWatcher {
    let pid: pid_t
    let element: AXUIElement
    private var observer: AXObserver?
    private var watchedWindows: Set<WindowID> = []
    private let onEvent: (String, AXUIElement) -> Void

    static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
    ]

    init?(pid: pid_t, onEvent: @escaping (String, AXUIElement) -> Void) {
        self.pid = pid
        self.onEvent = onEvent
        element = AX.app(pid)
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.onEvent(notification as String, element)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.appNotifications {
            AXObserverAddNotification(obs, element, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    func watch(_ window: AXUIElement, id: WindowID) {
        guard let observer, watchedWindows.insert(id).inserted else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.windowNotifications {
            AXObserverAddNotification(observer, window, n as CFString, refcon)
        }
    }

    func forget(_ id: WindowID) { watchedWindows.remove(id) }

    func invalidate() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
    }

    deinit { invalidate() }
}
