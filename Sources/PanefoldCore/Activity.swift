import Foundation

/// How the user arranged a window, for the Activity page. Numbers only.
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case placed
    case shortcut
    case drag, edgeResize, hoverBar, menuPanel
    case commandDrag
}

public struct DayCounts: Codable, Equatable, Sendable {
    public var placed = 0
    public var shortcuts: [String: Int] = [:]
    public var mouse: [String: Int] = [:]
    /// ⌘-drags count half to the keyboard and half to the mouse.
    public var commandDrags = 0

    public init() {}

    public var keyboardTotal: Double { Double(shortcuts.values.reduce(0, +)) + Double(commandDrags) / 2 }
    public var mouseTotal: Double { Double(mouse.values.reduce(0, +)) + Double(commandDrags) / 2 }
}

/// Per-day counts: windows placed, shortcuts used, mouse arrangements.
public struct ActivityLog: Codable, Equatable, Sendable {
    /// Keyed by day, "yyyy-MM-dd".
    public var days: [String: DayCounts] = [:]

    public init() {}

    /// Rough time a manual drag-and-resize takes, which tiling saves.
    public static let secondsSavedPerPlacement = 6.0
    public static let secondsSavedPerAction = 3.0

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func record(_ kind: ActivityKind, detail: String? = nil, on date: Date = Date()) {
        let k = Self.key(date)
        var d = days[k] ?? DayCounts()
        switch kind {
        case .placed: d.placed += 1
        case .shortcut: d.shortcuts[detail ?? "other", default: 0] += 1
        case .commandDrag: d.commandDrags += 1
        case .drag, .edgeResize, .hoverBar, .menuPanel: d.mouse[kind.rawValue, default: 0] += 1
        }
        days[k] = d
        prune(before: date.addingTimeInterval(-60 * 86400))
    }

    mutating func prune(before date: Date) {
        let cutoff = Self.key(date)
        days = days.filter { $0.key >= cutoff }
    }

    /// The last seven days, today included, added up.
    public func week(ending date: Date = Date(), calendar: Calendar = .current) -> DayCounts {
        var total = DayCounts()
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date), let d = days[Self.key(day, calendar: calendar)] else { continue }
            total.placed += d.placed
            total.commandDrags += d.commandDrags
            total.shortcuts.merge(d.shortcuts, uniquingKeysWith: +)
            total.mouse.merge(d.mouse, uniquingKeysWith: +)
        }
        return total
    }

    public static func timeSaved(_ d: DayCounts) -> TimeInterval {
        Double(d.placed) * secondsSavedPerPlacement + (d.keyboardTotal + d.mouseTotal) * secondsSavedPerAction
    }

    /// The most used shortcut, and one never used to try next.
    public static func favorites(_ d: DayCounts, suggestions: [String]) -> (mostUsed: String?, tryNext: String?) {
        let most = d.shortcuts.max { $0.value < $1.value }?.key
        let next = suggestions.first { d.shortcuts[$0, default: 0] == 0 }
        return (most, next)
    }
}

/// Decides when resting the pointer on a window should activate it.
/// It waits a moment, ignores the pointer while typing, and does nothing while a button is held.
public struct HoverFocusPolicy: Sendable {
    public var delay: TimeInterval = 0.18
    private var lastKey: TimeInterval = -.infinity
    private var movedSinceKey = true
    private var candidate: WindowID?
    private var candidateSince: TimeInterval = 0
    private var lastPointer: (x: Double, y: Double)?

    public init() {}

    public mutating func keyPressed(at time: TimeInterval) {
        lastKey = time
        movedSinceKey = false
        candidate = nil
    }

    /// Feed every pointer sample. Returns the window to activate, at most once per window.
    public mutating func pointer(x: Double, y: Double, over window: WindowID?, active: WindowID?, buttonsDown: Bool, at time: TimeInterval) -> WindowID? {
        if let p = lastPointer, abs(p.x - x) + abs(p.y - y) > 2 { movedSinceKey = true }
        lastPointer = (x, y)
        guard !buttonsDown, movedSinceKey, let window, window != active else {
            candidate = nil
            return nil
        }
        if candidate != window {
            candidate = window
            candidateSince = time
            return nil
        }
        if time - candidateSince >= delay {
            candidate = nil
            return window
        }
        return nil
    }
}
