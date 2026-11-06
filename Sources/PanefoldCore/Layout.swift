import CoreGraphics
import Foundation

/// How windows share a screen.
public enum LayoutKind: String, Codable, CaseIterable, Sendable {
    /// One big window, the rest folded beside it, 2×2 for four.
    case grid
    /// Every window side by side, full height.
    case columns
    /// Every window full width, one above the other.
    case rows
    /// One big window, the others in one column beside it.
    case side
}

/// The rough shape of a screen. Ultrawide and vertical screens get layouts of their own.
public enum ScreenShape: String, Codable, Sendable {
    case standard, ultrawide, vertical

    public init(size: CGSize) {
        if size.width >= size.height * 2 {
            self = .ultrawide
        } else if size.height > size.width {
            self = .vertical
        } else {
            self = .standard
        }
    }
}

/// How much room the main window starts with.
public enum MainSize: String, Codable, CaseIterable, Sendable {
    case half, sixty, twoThirds

    public var ratio: CGFloat {
        switch self {
        case .half: 0.5
        case .sixty: 0.6
        case .twoThirds: 2.0 / 3.0
        }
    }
}

public enum SplitAxis: String, Codable, Sendable {
    /// Children sit side by side, left to right.
    case horizontal
    /// Children sit one above the other, top to bottom.
    case vertical
}

/// A layout is a tree of splits whose leaves are tile indices (0 is the primary).
public indirect enum LayoutNode: Equatable, Sendable {
    case leaf(Int)
    case split(SplitAxis, [LayoutNode])

    public var leaves: [Int] {
        switch self {
        case .leaf(let i): [i]
        case .split(_, let children): children.flatMap(\.leaves)
        }
    }
}

public enum LayoutBuilder {
    /// The most windows any layout tiles on a screen of this shape.
    public static func hardLimit(_ kind: LayoutKind, shape: ScreenShape) -> Int {
        switch (kind, shape) {
        case (.side, .ultrawide), (.side, .vertical): 5
        case (.rows, .vertical): 3
        default: 4
        }
    }

    /// Vertical screens stack rows until a layout is picked on them, and have no Columns.
    public static func effectiveKind(_ kind: LayoutKind, shape: ScreenShape, pickedForScreen: Bool) -> LayoutKind {
        guard shape == .vertical else { return kind }
        if !pickedForScreen || kind == .columns { return .rows }
        return kind
    }

    public static func tree(_ kind: LayoutKind, count: Int, shape: ScreenShape) -> LayoutNode? {
        let n = min(count, hardLimit(kind, shape: shape))
        guard n > 0 else { return nil }
        if n == 1 { return .leaf(0) }
        let all = (0..<n).map(LayoutNode.leaf)
        let rest = Array(all.dropFirst())

        if shape == .vertical {
            switch kind {
            case .grid:
                switch n {
                case 2: return .split(.vertical, all)
                case 3: return .split(.vertical, [.leaf(0), .split(.horizontal, [.leaf(1), .leaf(2)])])
                default: return .split(.vertical, [.split(.horizontal, [.leaf(0), .leaf(1)]), .split(.horizontal, [.leaf(3), .leaf(2)])])
                }
            case .side:
                if n == 2 { return .split(.vertical, all) }
                if rest.count == 2 { return .split(.vertical, [.leaf(0), .split(.horizontal, rest)]) }
                var rows: [LayoutNode] = []
                var i = 0
                while i < rest.count {
                    let pair = Array(rest[i..<min(i + 2, rest.count)])
                    rows.append(pair.count == 1 ? pair[0] : .split(.horizontal, pair))
                    i += 2
                }
                return .split(.vertical, [.leaf(0), .split(.vertical, rows)])
            case .rows, .columns:
                return .split(.vertical, all)
            }
        }

        switch kind {
        case .grid:
            switch n {
            case 2: return .split(.horizontal, all)
            case 3: return .split(.horizontal, [.leaf(0), .split(.vertical, [.leaf(1), .leaf(2)])])
            default:
                return .split(.horizontal, [.split(.vertical, [.leaf(0), .leaf(3)]), .split(.vertical, [.leaf(1), .leaf(2)])])
            }
        case .columns:
            return .split(.horizontal, all)
        case .rows:
            return .split(.vertical, all)
        case .side:
            if n == 2 { return .split(.horizontal, all) }
            if shape == .ultrawide {
                return .split(.horizontal, [.leaf(0), .leaf(1), .split(.vertical, Array(all.dropFirst(2)))])
            }
            return .split(.horizontal, [.leaf(0), .split(.vertical, rest)])
        }
    }

    /// Starting weights for the root split. Every inner split starts equal.
    public static func rootWeights(_ kind: LayoutKind, count: Int, shape: ScreenShape, mainSize: MainSize, children: Int) -> [Double] {
        let r = Double(mainSize.ratio)
        if kind == .side, shape == .ultrawide, children == 3, count >= 3 {
            return [0.75 * r, 0.75 * (1 - r), 0.25]
        }
        if mainSize == .half || children < 2 {
            return Array(repeating: 1.0 / Double(children), count: children)
        }
        let others = (1 - r) / Double(children - 1)
        return [r] + Array(repeating: others, count: children - 1)
    }
}

/// What a split looked like after layout: used to turn an edge drag into new weights.
public struct SplitInfo: Equatable, Sendable {
    public var axis: SplitAxis
    public var rect: CGRect
    public var childRects: [CGRect]
    public var childMins: [CGSize]
}

public struct LayoutResult: Equatable, Sendable {
    /// Frame of every tile, by tile index.
    public var frames: [Int: CGRect] = [:]
    /// Tiles that can't get as big as their app needs.
    public var unfit: Set<Int> = []
    public var splits: [String: SplitInfo] = [:]
    /// For each tile, its ancestors from the root: (path of the split, index of the child containing it).
    public var ancestors: [Int: [(path: String, child: Int)]] = [:]

    public static func == (a: LayoutResult, b: LayoutResult) -> Bool {
        a.frames == b.frames && a.unfit == b.unfit && a.splits == b.splits
    }
}

/// Turns a layout tree into frames. Pure geometry, in top-left-origin screen coordinates.
public struct LayoutEngine: Sendable {
    public var area: CGRect
    public var gap: CGFloat
    public var tree: LayoutNode
    public var rootWeights: [Double]
    /// Custom weights by split path, from resizing.
    public var overrides: [String: [Double]]
    /// Smallest size each tile's app accepts.
    public var minSizes: [Int: CGSize]
    /// No tile is made smaller than this to make room for another app.
    public var floor = CGSize(width: 300, height: 200)

    public init(area: CGRect, gap: CGFloat, tree: LayoutNode, rootWeights: [Double], overrides: [String: [Double]] = [:], minSizes: [Int: CGSize] = [:]) {
        self.area = area
        self.gap = gap
        self.tree = tree
        self.rootWeights = rootWeights
        self.overrides = overrides
        self.minSizes = minSizes
    }

    public func layout() -> LayoutResult {
        var result = LayoutResult()
        let inner = area.insetBy(dx: gap, dy: gap)
        place(tree, in: inner, path: "", chain: [], into: &result)
        for (i, frame) in result.frames {
            let need = minSize(.leaf(i))
            if frame.width + 1 < need.width || frame.height + 1 < need.height { result.unfit.insert(i) }
        }
        return result
    }

    public func minSize(_ node: LayoutNode) -> CGSize {
        switch node {
        case .leaf(let i):
            let m = minSizes[i] ?? .zero
            return CGSize(width: max(m.width, floor.width), height: max(m.height, floor.height))
        case .split(let axis, let children):
            let mins = children.map(minSize)
            let gaps = gap * CGFloat(children.count - 1)
            if axis == .horizontal {
                return CGSize(width: mins.map(\.width).reduce(0, +) + gaps, height: mins.map(\.height).max() ?? 0)
            }
            return CGSize(width: mins.map(\.width).max() ?? 0, height: mins.map(\.height).reduce(0, +) + gaps)
        }
    }

    public func weights(at path: String, children: Int) -> [Double] {
        if let w = overrides[path], w.count == children, w.allSatisfy({ $0 > 0 }) { return w }
        if path.isEmpty, rootWeights.count == children { return rootWeights }
        return Array(repeating: 1.0 / Double(children), count: children)
    }

    private func place(_ node: LayoutNode, in rect: CGRect, path: String, chain: [(path: String, child: Int)], into result: inout LayoutResult) {
        switch node {
        case .leaf(let i):
            result.frames[i] = rect.integral
            result.ancestors[i] = chain
        case .split(let axis, let children):
            let mins = children.map(minSize)
            let total = (axis == .horizontal ? rect.width : rect.height) - gap * CGFloat(children.count - 1)
            let sizes = Self.distribute(total: total, weights: weights(at: path, children: children.count),
                                        mins: mins.map { axis == .horizontal ? $0.width : $0.height })
            var rects: [CGRect] = []
            var cursor = axis == .horizontal ? rect.minX : rect.minY
            for (k, size) in sizes.enumerated() {
                let r = axis == .horizontal
                    ? CGRect(x: cursor, y: rect.minY, width: size, height: rect.height)
                    : CGRect(x: rect.minX, y: cursor, width: rect.width, height: size)
                rects.append(r)
                cursor += size + gap
                place(children[k], in: r, path: "\(path)/\(k)", chain: chain + [(path, k)], into: &result)
            }
            result.splits[path] = SplitInfo(axis: axis, rect: rect, childRects: rects, childMins: mins)
        }
    }

    /// Shares `total` by weight, but never gives a child less than its minimum while others can spare room.
    /// Sizes are whole points and always add up to `total`.
    public static func distribute(total: CGFloat, weights: [Double], mins: [CGFloat]) -> [CGFloat] {
        let n = weights.count
        guard n > 0 else { return [] }
        var fixed = Array(repeating: false, count: n)
        var sizes = Array(repeating: CGFloat(0), count: n)
        if mins.reduce(0, +) <= total {
            var changed = true
            while changed {
                changed = false
                let fixedTotal = (0..<n).filter { fixed[$0] }.map { mins[$0] }.reduce(0, +)
                let freeWeight = (0..<n).filter { !fixed[$0] }.map { weights[$0] }.reduce(0, +)
                for i in 0..<n where !fixed[i] {
                    let s = (total - fixedTotal) * CGFloat(weights[i] / max(freeWeight, .ulpOfOne))
                    if s < mins[i] {
                        fixed[i] = true
                        changed = true
                    }
                    sizes[i] = s
                }
            }
            for i in 0..<n where fixed[i] { sizes[i] = mins[i] }
        } else {
            let sum = weights.reduce(0, +)
            for i in 0..<n { sizes[i] = total * CGFloat(weights[i] / sum) }
        }
        var rounded = sizes.map { $0.rounded(.down) }
        rounded[n - 1] += total.rounded(.down) - rounded.reduce(0, +)
        return rounded
    }
}

// MARK: - Resizing

public enum Resizer {
    /// New weights after the user dragged tile `leaf` from `old` to `new`. Only edges shared with another tile move.
    public static func weightsAfterDrag(_ result: LayoutResult, leaf: Int, old: CGRect, new: CGRect, gap: CGFloat) -> [String: [Double]] {
        var updates: [String: [Double]] = [:]
        let threshold: CGFloat = 2
        let moves: [(SplitAxis, Bool, CGFloat)] = [
            (.horizontal, false, new.minX - old.minX),
            (.horizontal, true, new.maxX - old.maxX),
            (.vertical, false, new.minY - old.minY),
            (.vertical, true, new.maxY - old.maxY),
        ]
        for (axis, trailing, delta) in moves where abs(delta) > threshold {
            guard let chain = result.ancestors[leaf] else { continue }
            for (path, child) in chain.reversed() {
                guard let info = result.splits[path], info.axis == axis else { continue }
                let neighbor = trailing ? child + 1 : child - 1
                guard info.childRects.indices.contains(neighbor) else { continue }
                var sizes = info.childRects.map { axis == .horizontal ? $0.width : $0.height }
                let mins = info.childMins.map { axis == .horizontal ? $0.width : $0.height }
                // Growing the trailing edge takes from the next child; growing the leading edge takes from the previous one.
                let grow = trailing ? delta : -delta
                let applied = clampTransfer(grow, into: child, from: neighbor, sizes: sizes, mins: mins)
                sizes[child] += applied
                sizes[neighbor] -= applied
                updates[path] = normalize(sizes)
                break
            }
        }
        return updates
    }

    /// Grows (positive) or shrinks (negative) a tile by `delta` points along each axis it can.
    /// Returns nil when nothing could change, meaning the tile is at its limit.
    public static func weightsAfterStep(_ result: LayoutResult, leaf: Int, delta: CGFloat) -> [String: [Double]]? {
        var updates: [String: [Double]] = [:]
        guard let chain = result.ancestors[leaf] else { return nil }
        for axis in [SplitAxis.horizontal, .vertical] {
            guard let (path, child) = chain.reversed().first(where: { result.splits[$0.path]?.axis == axis }),
                  let info = result.splits[path] else { continue }
            var sizes = info.childRects.map { axis == .horizontal ? $0.width : $0.height }
            let mins = info.childMins.map { axis == .horizontal ? $0.width : $0.height }
            let others = sizes.indices.filter { $0 != child }
            var moved: CGFloat = 0
            if delta > 0 {
                let spare = others.map { max(0, sizes[$0] - mins[$0]) }
                let totalSpare = spare.reduce(0, +)
                moved = min(delta, totalSpare)
                guard moved >= 1 else { continue }
                for (k, i) in others.enumerated() { sizes[i] -= moved * spare[k] / totalSpare }
                sizes[child] += moved
            } else {
                moved = min(-delta, max(0, sizes[child] - mins[child]))
                guard moved >= 1 else { continue }
                let share = moved / CGFloat(others.count)
                for i in others { sizes[i] += share }
                sizes[child] -= moved
            }
            updates[path] = normalize(sizes)
        }
        return updates.isEmpty ? nil : updates
    }

    static func clampTransfer(_ amount: CGFloat, into a: Int, from b: Int, sizes: [CGFloat], mins: [CGFloat]) -> CGFloat {
        if amount > 0 { return min(amount, max(0, sizes[b] - mins[b])) }
        return max(amount, -max(0, sizes[a] - mins[a]))
    }

    static func normalize(_ sizes: [CGFloat]) -> [Double] {
        let total = sizes.reduce(0, +)
        return sizes.map { Double($0 / max(total, 1)) }
    }
}

// MARK: - Capacity

public enum FitIssue: Equatable, Sendable {
    /// The screen is too small for that many columns or rows.
    case screenTooSmall
    /// The app at this tile index needs more room than that many windows leave.
    case appNeedsRoom(tile: Int)
}

public enum Capacity {
    /// A tile smaller than this isn't usable, so layouts other than Grid hold fewer windows on small screens.
    public static let usable = CGSize(width: 400, height: 300)

    /// Why `count` windows don't fit, or nil when they do.
    public static func issue(count: Int, kind: LayoutKind, shape: ScreenShape, area: CGRect, gap: CGFloat,
                             mainSize: MainSize, minSizes: [Int: CGSize] = [:]) -> FitIssue? {
        if count > LayoutBuilder.hardLimit(kind, shape: shape) { return .screenTooSmall }
        guard count > 1, let tree = LayoutBuilder.tree(kind, count: count, shape: shape) else { return nil }
        let rootChildren: Int = if case .split(_, let c) = tree { c.count } else { 1 }
        let weights = LayoutBuilder.rootWeights(kind, count: count, shape: shape, mainSize: mainSize, children: rootChildren)
        if kind != .grid {
            let plain = LayoutEngine(area: area, gap: gap, tree: tree, rootWeights: weights).layout()
            if plain.frames.values.contains(where: { $0.width < usable.width - 1 || $0.height < usable.height - 1 }) {
                return .screenTooSmall
            }
        }
        let fitted = LayoutEngine(area: area, gap: gap, tree: tree, rootWeights: weights, minSizes: minSizes).layout()
        if let bad = fitted.unfit.min() { return .appNeedsRoom(tile: bad) }
        return nil
    }

    /// The most windows that fit, up to `wanted`.
    public static func fitting(_ wanted: Int, kind: LayoutKind, shape: ScreenShape, area: CGRect, gap: CGFloat, mainSize: MainSize) -> Int {
        var n = min(wanted, LayoutBuilder.hardLimit(kind, shape: shape))
        while n > 1, issue(count: n, kind: kind, shape: shape, area: area, gap: gap, mainSize: mainSize) != nil { n -= 1 }
        return max(n, 1)
    }
}
