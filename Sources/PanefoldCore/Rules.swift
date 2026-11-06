import CoreGraphics
import Foundation

/// "Always float windows like this one": an app, and the first words of the window's title.
public struct FloatRule: Codable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var appName: String
    public var prefix: String

    public var id: String { bundleID + "\u{1F}" + prefix }

    public init(bundleID: String, appName: String, prefix: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.prefix = prefix
    }

    /// The first two words of a title, which is what a rule looks for. Nil for a window with no title.
    public static func prefix(forTitle title: String) -> String? {
        let words = title.split(whereSeparator: \.isWhitespace).prefix(2)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    public func matches(bundleID: String, title: String) -> Bool {
        guard bundleID == self.bundleID, let p = Self.prefix(forTitle: title) else { return false }
        let wanted = prefix.split(whereSeparator: \.isWhitespace)
        let have = p.split(whereSeparator: \.isWhitespace)
        return have.count >= wanted.count && Array(have.prefix(wanted.count)) == wanted
    }
}

public enum DefaultExclusions {
    /// Small tools and fixed-shape windows that look wrong stretched into a tile.
    public static let bundleIDs: [String: String] = [
        "com.apple.ScreenContinuity": "iPhone Mirroring",
        "com.apple.iphonesimulator": "Simulator",
        "com.apple.calculator": "Calculator",
        "com.apple.systempreferences": "System Settings",
        "com.apple.Stickies": "Stickies",
        "com.apple.clock": "Clock",
        "com.apple.PhotoBooth": "Photo Booth",
        "com.apple.QuickTimePlayerX": "QuickTime Player",
        "com.apple.Magnifier": "Magnifier",
        "com.apple.DeskView": "Desk View",
        "com.apple.DigitalColorMeter": "Digital Color Meter",
        "com.apple.screenshot.launcher": "Screenshot",
        "com.apple.archiveutility": "Archive Utility",
        "com.apple.installer": "Installer",
        "com.apple.iOSAppInstaller": "iOS App Installer",
        "com.apple.MigrateAssistant": "Migration Assistant",
        "com.apple.CaptiveNetworkAssistant": "Wi-Fi Sign-In",
        "com.apple.problemreporter": "Problem Reporter",
    ]
}

/// Decides whether an app's windows go into the layout.
public struct ExclusionList: Codable, Equatable, Sendable {
    /// Apps the user added, by bundle ID, with their names.
    public var added: [String: String] = [:]
    /// Default exclusions the user chose to tile anyway.
    public var removedDefaults: Set<String> = []

    public init() {}

    public func isExcluded(_ bundleID: String) -> Bool {
        added[bundleID] != nil || (DefaultExclusions.bundleIDs[bundleID] != nil && !removedDefaults.contains(bundleID))
    }

    public mutating func exclude(_ bundleID: String, name: String) {
        if DefaultExclusions.bundleIDs[bundleID] != nil {
            removedDefaults.remove(bundleID)
        } else {
            added[bundleID] = name
        }
    }

    public mutating func include(_ bundleID: String) {
        added[bundleID] = nil
        if DefaultExclusions.bundleIDs[bundleID] != nil { removedDefaults.insert(bundleID) }
    }

    /// Every excluded app, defaults marked, sorted by name.
    public var entries: [(bundleID: String, name: String, isDefault: Bool)] {
        let defaults = DefaultExclusions.bundleIDs.filter { !removedDefaults.contains($0.key) }.map { ($0.key, $0.value, true) }
        return (defaults + added.map { ($0.key, $0.value, false) }).sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}

/// Learns the smallest size an app accepts, carefully: a size counts only when the app refuses it twice.
public struct MinSizeLearner: Codable, Equatable, Sendable {
    /// Learned minimums by bundle ID. A zero side means that side has no known limit.
    public var learned: [String: CGSize] = [:]
    /// Apps the user told us never to learn for.
    public var neverLearn: Set<String> = []
    /// A first refusal, waiting for a second one at the same requested size.
    private var pending: [String: Refusal] = [:]

    struct Refusal: Codable, Equatable, Sendable {
        var requested: CGSize
        var actual: CGSize
    }

    /// Being a few points bigger than asked isn't refusing.
    public static let slack: CGFloat = 8

    public init() {}

    enum CodingKeys: String, CodingKey { case learned, neverLearn }

    public func minimum(for bundleID: String) -> CGSize? {
        neverLearn.contains(bundleID) ? nil : learned[bundleID]
    }

    /// Records the size a window ended up at after we asked for `requested`. Returns true if a minimum was learned.
    @discardableResult
    public mutating func observe(bundleID: String, requested: CGSize, actual: CGSize, screen: CGSize) -> Bool {
        guard !neverLearn.contains(bundleID) else { return false }
        let refusedW = actual.width > requested.width + Self.slack
        let refusedH = actual.height > requested.height + Self.slack
        guard refusedW || refusedH else {
            if pending[bundleID]?.requested == requested { pending[bundleID] = nil }
            return false
        }
        // A "minimum" of nearly the whole screen is the app sizing itself, not a limit.
        if actual.width > screen.width * 0.9, actual.height > screen.height * 0.9 { return false }
        let refusal = Refusal(requested: requested, actual: actual)
        guard let first = pending[bundleID], Self.close(first.requested, requested), Self.close(first.actual, actual) else {
            pending[bundleID] = refusal
            return false
        }
        pending[bundleID] = nil
        let old = learned[bundleID] ?? .zero
        let new = CGSize(width: refusedW ? max(old.width, actual.width) : old.width,
                         height: refusedH ? max(old.height, actual.height) : old.height)
        guard new != old else { return false }
        learned[bundleID] = new
        return true
    }

    /// The user made a window smaller than we thought possible, and the app went along.
    public mutating func userResized(bundleID: String, to size: CGSize) {
        guard var m = learned[bundleID] else { return }
        if m.width > 0, size.width < m.width - Self.slack { m.width = size.width }
        if m.height > 0, size.height < m.height - Self.slack { m.height = size.height }
        learned[bundleID] = m
    }

    public mutating func forget(_ bundleID: String) { learned[bundleID] = nil }
    public mutating func forgetAll() { learned.removeAll(); pending.removeAll() }

    public mutating func setNeverLearn(_ bundleID: String, _ never: Bool) {
        if never {
            neverLearn.insert(bundleID)
            learned[bundleID] = nil
        } else {
            neverLearn.remove(bundleID)
        }
    }

    static func close(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
    }
}
