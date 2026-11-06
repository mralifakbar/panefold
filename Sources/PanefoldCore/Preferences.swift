import CoreGraphics
import Foundation

public enum AppearanceChoice: String, Codable, CaseIterable, Sendable { case system, light, dark }

public enum Highlight: String, Codable, CaseIterable, Sendable { case none, borderActive, borderAll, glowActive }

public enum HighlightColor: Codable, Equatable, Hashable, Sendable {
    case accent
    case preset(String)
    /// RGB as 0xRRGGBB.
    case custom(UInt32)

    public static let presets: [(name: String, rgb: UInt32)] = [
        ("Blue", 0x0A84FF), ("Purple", 0xBF5AF2), ("Pink", 0xFF375F), ("Red", 0xFF453A),
        ("Orange", 0xFF9F0A), ("Yellow", 0xFFD60A), ("Green", 0x30D158), ("Teal", 0x40C8E0), ("Graphite", 0x8E8E93),
    ]

    /// The color as 0xRRGGBB, or nil for the accent color.
    public var rgb: UInt32? {
        switch self {
        case .accent: nil
        case .preset(let name): Self.presets.first { $0.name == name }?.rgb
        case .custom(let rgb): rgb
        }
    }
}

public enum CleanBackground: String, Codable, CaseIterable, Sendable {
    case graphite, mist, stone

    public var rgb: UInt32 {
        switch self {
        case .graphite: 0x2B2D31
        case .mist: 0xDDE3EA
        case .stone: 0xB8B0A2
        }
    }
}

public enum MoveIntoFullScreen: String, Codable, CaseIterable, Sendable { case swap, stack }

public enum IconStyle: String, Codable, CaseIterable, Sendable { case panefold, ink, sunrise, mint, night, paper, mono }

/// Space kept free along each edge of a screen, in points.
public struct EdgeInsets: Codable, Equatable, Hashable, Sendable {
    public var top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0

    public init(top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public static let range: ClosedRange<CGFloat> = 0...200

    /// `rect` in top-left-origin coordinates, shrunk by these insets.
    public func apply(to rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + left, y: rect.minY + top,
               width: max(0, rect.width - left - right), height: max(0, rect.height - top - bottom))
    }

    public var isZero: Bool { top == 0 && bottom == 0 && left == 0 && right == 0 }
}

/// Every setting. Decoding is forgiving: a missing or unreadable value takes its default,
/// so adding a setting never resets the others.
public struct Preferences: Codable, Equatable, Sendable {
    // General
    public var tilingEnabled = true
    public var openAtLogin = true
    public var appearance: AppearanceChoice = .system
    public var iconStyle: IconStyle = .panefold
    public var checkForUpdates = true
    public var onboardingDone = false

    // Layout
    public var layout: LayoutKind = .grid
    public var mainSize: MainSize = .half
    public var windowsPerScreen = 3
    public var newWindows: NewWindowPlacement = .nextFreeTile
    public var whenFull: FullScreenPolicy = .stack
    public var movingIntoFull: MoveIntoFullScreen = .swap
    public var gap: CGFloat = 8

    // Docks and bars
    public var insetsByScreen: [String: EdgeInsets] = [:]
    public var sameInsetsEverywhere = false
    public var sharedInsets = EdgeInsets()

    // Highlight
    public var highlight: Highlight = .none
    public var borderWidth: CGFloat = 3
    public var highlightColor: HighlightColor = .accent

    // Focus
    public var noPeek = false
    public var dimAmount: Double = 0.5
    public var blurOthers = true
    public var cleanBackground: CleanBackground = .graphite

    // Mouse
    public var quickActions = true
    public var hoverFocus = false

    // Keyboard
    public var shortcutsEnabled = true
    public var shortcuts = ShortcutBindings()

    // Apps
    public var exclusions = ExclusionList()
    public var floatRules: [FloatRule] = []
    public var roomCardMuted: Set<String> = []

    // Activity
    public var countActivity = true

    public init() {}

    public static let gapRange: ClosedRange<CGFloat> = 0...24
    public static let borderRange: ClosedRange<CGFloat> = 2...6
    public static let dimRange: ClosedRange<Double> = 0.1...0.9

    /// The space actually used between windows: a border or glow needs room of its own.
    public var effectiveGap: CGFloat {
        switch highlight {
        case .none: gap
        case .borderActive, .borderAll: max(gap, borderWidth + 1)
        case .glowActive: max(gap, 4)
        }
    }

    public func insets(for screenID: String) -> EdgeInsets {
        sameInsetsEverywhere ? sharedInsets : (insetsByScreen[screenID] ?? EdgeInsets())
    }

    public func isFloatedByRule(bundleID: String, title: String) -> Bool {
        floatRules.contains { $0.matches(bundleID: bundleID, title: title) }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case tilingEnabled, openAtLogin, appearance, iconStyle, checkForUpdates, onboardingDone
        case layout, mainSize, windowsPerScreen, newWindows, whenFull, movingIntoFull, gap
        case insetsByScreen, sameInsetsEverywhere, sharedInsets
        case highlight, borderWidth, highlightColor
        case noPeek, dimAmount, blurOthers, cleanBackground
        case quickActions, hoverFocus
        case shortcutsEnabled, shortcuts
        case exclusions, floatRules, roomCardMuted
        case countActivity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = Preferences()
        tilingEnabled = v(.tilingEnabled, d.tilingEnabled)
        openAtLogin = v(.openAtLogin, d.openAtLogin)
        appearance = v(.appearance, d.appearance)
        iconStyle = v(.iconStyle, d.iconStyle)
        checkForUpdates = v(.checkForUpdates, d.checkForUpdates)
        onboardingDone = v(.onboardingDone, d.onboardingDone)
        layout = v(.layout, d.layout)
        mainSize = v(.mainSize, d.mainSize)
        windowsPerScreen = min(5, max(1, v(.windowsPerScreen, d.windowsPerScreen)))
        newWindows = v(.newWindows, d.newWindows)
        whenFull = v(.whenFull, d.whenFull)
        movingIntoFull = v(.movingIntoFull, d.movingIntoFull)
        gap = min(Self.gapRange.upperBound, max(0, v(.gap, d.gap)))
        insetsByScreen = v(.insetsByScreen, d.insetsByScreen)
        sameInsetsEverywhere = v(.sameInsetsEverywhere, d.sameInsetsEverywhere)
        sharedInsets = v(.sharedInsets, d.sharedInsets)
        highlight = v(.highlight, d.highlight)
        borderWidth = min(6, max(2, v(.borderWidth, d.borderWidth)))
        highlightColor = v(.highlightColor, d.highlightColor)
        noPeek = v(.noPeek, d.noPeek)
        dimAmount = min(0.9, max(0.1, v(.dimAmount, d.dimAmount)))
        blurOthers = v(.blurOthers, d.blurOthers)
        cleanBackground = v(.cleanBackground, d.cleanBackground)
        quickActions = v(.quickActions, d.quickActions)
        hoverFocus = v(.hoverFocus, d.hoverFocus)
        shortcutsEnabled = v(.shortcutsEnabled, d.shortcutsEnabled)
        shortcuts = v(.shortcuts, d.shortcuts)
        exclusions = v(.exclusions, d.exclusions)
        floatRules = v(.floatRules, d.floatRules)
        roomCardMuted = v(.roomCardMuted, d.roomCardMuted)
        countActivity = v(.countActivity, d.countActivity)
    }
}
