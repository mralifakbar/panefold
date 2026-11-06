import AppKit
import PanefoldCore

/// A connected display, in top-left-origin global coordinates (the ones Accessibility uses).
struct Display: Identifiable, Equatable {
    /// The display's UUID from macOS: stable across restarts and reconnects.
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let frame: CGRect
    /// Below the menu bar and beside the Dock.
    let visible: CGRect
    let isMain: Bool

    var shape: ScreenShape { ScreenShape(size: frame.size) }

    func geometry(insets: EdgeInsets) -> ScreenGeometry {
        ScreenGeometry(frame: frame, area: insets.apply(to: visible))
    }

    /// Converts a top-left-origin rect to AppKit's bottom-left origin, for placing our own windows.
    static func toCocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func fromCocoa(_ r: CGRect) -> CGRect { toCocoa(r) }

    static func fromCocoa(_ p: CGPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    /// Where the pointer is, top-left origin.
    static var mouse: CGPoint { fromCocoa(NSEvent.mouseLocation) }

    static func all() -> [Display] {
        let dock = DockPrefs.read()
        return NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let did = CGDirectDisplayID(number.uint32Value)
            let uuid = CGDisplayCreateUUIDFromDisplayID(did).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(did)"
            let frame = toCocoa(screen.frame)
            var visible = toCocoa(screen.visibleFrame)
            // A hidden Dock still leaves a sliver in visibleFrame; let windows reach the edge.
            if dock.autohide {
                switch dock.orientation {
                case "left" where visible.minX - frame.minX < 10:
                    visible = CGRect(x: frame.minX, y: visible.minY, width: visible.maxX - frame.minX, height: visible.height)
                case "right" where frame.maxX - visible.maxX < 10:
                    visible.size.width = frame.maxX - visible.minX
                case "bottom" where frame.maxY - visible.maxY < 10:
                    visible.size.height = frame.maxY - visible.minY
                default: break
                }
            }
            return Display(id: uuid, displayID: did, name: screen.localizedName, frame: frame, visible: visible, isMain: index == 0)
        }
    }

    static func containing(_ rect: CGRect, in displays: [Display]) -> Display? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let d = displays.first(where: { $0.frame.contains(center) }) { return d }
        return displays.max { a, b in
            a.frame.intersection(rect).width * a.frame.intersection(rect).height < b.frame.intersection(rect).width * b.frame.intersection(rect).height
        }
    }

    static func containing(_ point: CGPoint, in displays: [Display]) -> Display? {
        displays.first { $0.frame.contains(point) } ?? displays.first
    }
}

enum DockPrefs {
    static func read() -> (autohide: Bool, orientation: String) {
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
        return (autohide, orientation)
    }
}

/// The Space each display shows, from the window server. Private API, looked up at runtime so a missing
/// symbol only means every Space shares one layout.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64

    private static let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    private static let mainConnection: MainConnection? = symbol("CGSMainConnectionID")
    private static let currentSpace: CurrentSpace? = symbol("CGSManagedDisplayGetCurrentSpace")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let s = dlsym(handle, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    static func current(for display: Display) -> UInt64 {
        guard let mainConnection, let currentSpace else { return 0 }
        return currentSpace(mainConnection(), display.id as CFString)
    }

    /// The key a screen's layout is kept under: the display and the Space it shows.
    static func key(for display: Display) -> String { "\(display.id)#\(current(for: display))" }

    static func displayID(fromKey key: String) -> String { String(key.split(separator: "#").first ?? "") }
}

/// What the window server knows about on-screen windows, front to back.
struct ServerWindow {
    let id: WindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
}

enum WindowServer {
    static func onScreen() -> [ServerWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return ServerWindow(id: id, pid: pid, layer: layer,
                                bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
    }
}
