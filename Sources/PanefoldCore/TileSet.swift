import Foundation

/// A window's number in the window server (CGWindowID).
public typealias WindowID = UInt32

/// One place in the layout. It can hold a stack of windows; the first one shows.
public struct Tile: Codable, Equatable, Sendable {
    /// `windows[0]` is showing. The rest wait behind it, most recently shown first.
    public var windows: [WindowID]

    public init(_ windows: [WindowID]) { self.windows = windows }

    public var showing: WindowID { windows[0] }
    public var isStacked: Bool { windows.count > 1 }
}

public enum NewWindowPlacement: String, Codable, CaseIterable, Sendable {
    /// A new window takes the next free tile.
    case nextFreeTile
    /// A new window takes the big tile and the others move down one place.
    case mainTile
}

public enum FullScreenPolicy: String, Codable, CaseIterable, Sendable {
    /// A window opened on a full screen joins the tile you're in, on top.
    case stack
    /// It floats in the middle until a tile frees up.
    case floatInMiddle
}

public enum InsertOutcome: Equatable, Sendable {
    case newTile(Int)
    case stacked(tile: Int)
    case overflowed
    case alreadyThere
}

/// The tiled windows of one screen in one Space: their order, stacks, and the windows waiting for room.
public struct TileSet: Codable, Equatable, Sendable {
    public var tiles: [Tile] = []
    /// Windows floated in the middle because the screen was full, oldest first.
    public var overflow: [WindowID] = []
    /// How many tiles this screen holds.
    public var capacity: Int

    public init(capacity: Int, tiles: [Tile] = [], overflow: [WindowID] = []) {
        self.capacity = max(1, capacity)
        self.tiles = tiles
        self.overflow = overflow
    }

    public var showing: [WindowID] { tiles.map(\.showing) }
    public var allTiled: [WindowID] { tiles.flatMap(\.windows) }
    public var isEmpty: Bool { tiles.isEmpty && overflow.isEmpty }
    public var hasStacks: Bool { tiles.contains(where: \.isStacked) }

    public func tileIndex(of w: WindowID) -> Int? { tiles.firstIndex { $0.windows.contains(w) } }
    public func contains(_ w: WindowID) -> Bool { tileIndex(of: w) != nil || overflow.contains(w) }
    public func isShowing(_ w: WindowID) -> Bool { tiles.contains { $0.showing == w } }

    @discardableResult
    public mutating func insert(_ w: WindowID, active: WindowID?, placement: NewWindowPlacement = .nextFreeTile,
                                whenFull: FullScreenPolicy = .stack) -> InsertOutcome {
        if contains(w) { return .alreadyThere }
        switch placement {
        case .nextFreeTile:
            if tiles.count < capacity {
                tiles.append(Tile([w]))
                return .newTile(tiles.count - 1)
            }
            switch whenFull {
            case .floatInMiddle:
                overflow.append(w)
                return .overflowed
            case .stack:
                let target = active.flatMap(tileIndex(of:)) ?? tiles.count - 1
                tiles[target].windows.insert(w, at: 0)
                return .stacked(tile: target)
            }
        case .mainTile:
            tiles.insert(Tile([w]), at: 0)
            if tiles.count > capacity {
                let pushed = tiles.removeLast()
                switch whenFull {
                case .stack: tiles[tiles.count - 1].windows.append(contentsOf: pushed.windows)
                case .floatInMiddle: overflow.append(contentsOf: pushed.windows)
                }
            }
            return .newTile(0)
        }
    }

    /// Takes a window out. When a whole tile goes, the oldest window waiting in the middle gets it.
    @discardableResult
    public mutating func remove(_ w: WindowID) -> Bool {
        if let i = overflow.firstIndex(of: w) {
            overflow.remove(at: i)
            return true
        }
        guard let t = tileIndex(of: w) else { return false }
        tiles[t].windows.removeAll { $0 == w }
        if tiles[t].windows.isEmpty {
            tiles.remove(at: t)
            if !overflow.isEmpty, tiles.count < capacity { tiles.append(Tile([overflow.removeFirst()])) }
        }
        return true
    }

    /// Changes how many tiles the screen holds. Fewer: the last tiles' windows wait in the tile before them
    /// (or float). More: waiting windows get their own tile again.
    public mutating func setCapacity(_ n: Int, whenFull: FullScreenPolicy = .stack) {
        capacity = max(1, n)
        if tiles.count > capacity {
            let removed = tiles[capacity...].flatMap(\.windows)
            tiles.removeSubrange(capacity...)
            switch whenFull {
            case .stack: tiles[capacity - 1].windows.append(contentsOf: removed)
            case .floatInMiddle: overflow.append(contentsOf: removed)
            }
        }
        while tiles.count < capacity {
            if !overflow.isEmpty {
                tiles.append(Tile([overflow.removeFirst()]))
            } else if let donor = tiles.indices.filter({ tiles[$0].isStacked }).max(by: { tiles[$0].windows.count < tiles[$1].windows.count }) {
                tiles.append(Tile([tiles[donor].windows.removeLast()]))
            } else {
                break
            }
        }
    }

    /// Swaps the showing windows of two tiles. Each stack stays with its tile.
    @discardableResult
    public mutating func swap(_ a: WindowID, _ b: WindowID) -> Bool {
        guard a != b, let i = tileIndex(of: a), let j = tileIndex(of: b), i != j else { return false }
        bringToFront(a)
        bringToFront(b)
        tiles[i].windows[0] = b
        tiles[j].windows[0] = a
        return true
    }

    @discardableResult
    public mutating func makePrimary(_ w: WindowID) -> Bool {
        guard let first = tiles.first, tileIndex(of: w) != 0 else { return false }
        return swap(w, first.showing)
    }

    /// Shows the next (or previous) window in the tile holding `w`. Returns the window now showing.
    @discardableResult
    public mutating func cycle(tileOf w: WindowID, forward: Bool) -> WindowID? {
        guard let t = tileIndex(of: w), tiles[t].isStacked else { return nil }
        if forward {
            tiles[t].windows.append(tiles[t].windows.removeFirst())
        } else {
            tiles[t].windows.insert(tiles[t].windows.removeLast(), at: 0)
        }
        return tiles[t].showing
    }

    /// Notes that `w` came forward (⌘-Tab, a click, the Dock). Returns true if what shows in its tile changed.
    @discardableResult
    public mutating func bringToFront(_ w: WindowID) -> Bool {
        guard let t = tileIndex(of: w), tiles[t].showing != w else { return false }
        tiles[t].windows.removeAll { $0 == w }
        tiles[t].windows.insert(w, at: 0)
        return true
    }

    /// Moves `w` on top of the tile that holds `target`.
    @discardableResult
    public mutating func stack(_ w: WindowID, onto target: WindowID) -> Bool {
        guard w != target, tileIndex(of: target) != nil else { return false }
        if tileIndex(of: w) == tileIndex(of: target) { return bringToFront(w) }
        remove(w)
        guard let t = tileIndex(of: target) else { return false }
        tiles[t].windows.insert(w, at: 0)
        return true
    }

    /// Puts `w` into tile `index`, sending whatever showed there behind it.
    @discardableResult
    public mutating func place(_ w: WindowID, inTile index: Int) -> Bool {
        guard tiles.indices.contains(index) else { return false }
        if tileIndex(of: w) == index { return bringToFront(w) }
        let shown = tiles[index].showing
        remove(w)
        guard let t = tileIndex(of: shown) else { return false }
        tiles[t].windows.insert(w, at: 0)
        return true
    }

    /// Keeps only windows that still exist, in their order.
    public mutating func retain(_ alive: Set<WindowID>) {
        for w in allTiled + overflow where !alive.contains(w) { remove(w) }
    }
}
