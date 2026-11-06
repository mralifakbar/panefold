import CoreGraphics
import Foundation

/// Everything one screen in one Space remembers: its windows, its own layout and count if picked, its sizes.
public struct ScreenSpace: Codable, Equatable, Sendable {
    public var tiles: TileSet
    /// Picked for this screen in the menu bar panel or with a shortcut; wins over Settings.
    public var layoutPick: LayoutKind?
    public var countPick: Int?
    /// Custom sizes, by "<layout>-<count><split path>".
    public var sizes: [String: [Double]] = [:]
    /// The window filling the screen in focus mode.
    public var zoomed: WindowID?

    public init(capacity: Int) { tiles = TileSet(capacity: capacity) }

    public var hasCustomSizes: Bool { !sizes.isEmpty }

    static func sizeKey(_ kind: LayoutKind, _ count: Int) -> String { "\(kind.rawValue)-\(count)" }

    public func overrides(kind: LayoutKind, count: Int) -> [String: [Double]] {
        let prefix = Self.sizeKey(kind, count)
        var out: [String: [Double]] = [:]
        for (k, v) in sizes where k.hasPrefix(prefix + "/") || k == prefix {
            out[String(k.dropFirst(prefix.count))] = v
        }
        return out
    }

    public mutating func setOverrides(_ updates: [String: [Double]], kind: LayoutKind, count: Int) {
        let prefix = Self.sizeKey(kind, count)
        for (path, w) in updates { sizes[prefix + path] = w }
    }
}

/// Geometry of a screen, in top-left-origin global coordinates.
public struct ScreenGeometry: Equatable, Sendable {
    /// The whole display.
    public var frame: CGRect
    /// Below the menu bar and beside the Dock, minus space kept free for other apps' bars.
    public var area: CGRect

    public init(frame: CGRect, area: CGRect) {
        self.frame = frame
        self.area = area
    }

    public var shape: ScreenShape { ScreenShape(size: frame.size) }
}

public struct Plan: Equatable, Sendable {
    public var kind: LayoutKind
    public var count: Int
    /// Where every tiled window goes. Stacked windows share their tile's frame.
    public var frames: [WindowID: CGRect] = [:]
    /// Tile frames, by index.
    public var tileFrames: [CGRect] = []
    /// Windows whose app can't get small enough for their tile.
    public var unfit: [WindowID] = []
    public var result = LayoutResult()
}

public enum Planner {
    /// The layout and count a screen uses: its own pick, else Settings, limited to what fits.
    public static func shape(of space: ScreenSpace, prefs: Preferences, geometry: ScreenGeometry) -> (kind: LayoutKind, capacity: Int) {
        let shape = geometry.shape
        let kind = LayoutBuilder.effectiveKind(space.layoutPick ?? prefs.layout, shape: shape, pickedForScreen: space.layoutPick != nil)
        let wanted = space.countPick ?? prefs.windowsPerScreen
        let capacity = Capacity.fitting(wanted, kind: kind, shape: shape, area: geometry.area, gap: prefs.effectiveGap, mainSize: prefs.mainSize)
        return (kind, capacity)
    }

    public static func plan(_ space: ScreenSpace, prefs: Preferences, geometry: ScreenGeometry, minSize: (WindowID) -> CGSize?) -> Plan {
        let (kind, _) = shape(of: space, prefs: prefs, geometry: geometry)
        let tiles = space.tiles.tiles
        var plan = Plan(kind: kind, count: tiles.count)
        guard !tiles.isEmpty, let tree = LayoutBuilder.tree(kind, count: tiles.count, shape: geometry.shape) else { return plan }
        let rootChildren: Int = if case .split(_, let c) = tree { c.count } else { 1 }
        var mins: [Int: CGSize] = [:]
        for (i, t) in tiles.enumerated() {
            // A stack needs room for its biggest window.
            let sizes = t.windows.compactMap(minSize)
            if !sizes.isEmpty {
                mins[i] = CGSize(width: sizes.map(\.width).max()!, height: sizes.map(\.height).max()!)
            }
        }
        let engine = LayoutEngine(
            area: geometry.area, gap: prefs.effectiveGap, tree: tree,
            rootWeights: LayoutBuilder.rootWeights(kind, count: tiles.count, shape: geometry.shape, mainSize: prefs.mainSize, children: rootChildren),
            overrides: space.overrides(kind: kind, count: tiles.count), minSizes: mins
        )
        let result = engine.layout()
        plan.result = result
        plan.tileFrames = (0..<tiles.count).map { result.frames[$0] ?? .zero }
        for (i, t) in tiles.enumerated() {
            for w in t.windows { plan.frames[w] = plan.tileFrames[i] }
            if result.unfit.contains(i) { plan.unfit.append(t.showing) }
        }
        if let z = space.zoomed, plan.frames[z] != nil {
            plan.frames[z] = geometry.area.insetBy(dx: prefs.effectiveGap, dy: prefs.effectiveGap).integral
        }
        return plan
    }

    /// A floating window's frame: centered at a comfortable size, or at its own size if bigger.
    public static func centered(in area: CGRect, size: CGSize? = nil) -> CGRect {
        let w = min(area.width, max(size?.width ?? 0, area.width * 0.6))
        let h = min(area.height, max(size?.height ?? 0, area.height * 0.7))
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h).integral
    }
}
