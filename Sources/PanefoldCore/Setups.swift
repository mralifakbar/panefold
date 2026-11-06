import Foundation

/// One screen of a setup: which app sits in which tile, with the layout and sizes.
public struct SetupScreen: Codable, Equatable, Sendable {
    /// The display's identifier from macOS.
    public var screenID: String
    public var screenName: String
    public var layout: LayoutKind
    public var capacity: Int
    /// Bundle IDs per tile, the app showing first.
    public var tiles: [[String]]
    /// Custom sizes by split path.
    public var sizes: [String: [Double]]

    public init(screenID: String, screenName: String, layout: LayoutKind, capacity: Int, tiles: [[String]], sizes: [String: [Double]] = [:]) {
        self.screenID = screenID
        self.screenName = screenName
        self.layout = layout
        self.capacity = capacity
        self.tiles = tiles
        self.sizes = sizes
    }

    /// Every app in this screen, each once, in tile order.
    public var apps: [String] {
        var seen = Set<String>()
        return tiles.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
}

/// A named arrangement of apps across screens.
public struct Setup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var shortcut: KeyCombo?
    public var screens: [SetupScreen]

    public init(id: UUID = UUID(), name: String, shortcut: KeyCombo? = nil, screens: [SetupScreen]) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.screens = screens
    }

    public var apps: [String] {
        var seen = Set<String>()
        return screens.flatMap(\.apps).filter { seen.insert($0).inserted }
    }

    /// The arrangement, without names or keys: two setups with the same signature look the same on screen.
    public var signature: [String: [[String]]] {
        Dictionary(uniqueKeysWithValues: screens.map { ($0.screenID, $0.tiles.map { Array($0.prefix(1)) }) })
    }
}

public enum SetupPlanner {
    /// Which connected screen each of the setup's screens goes to. A screen that isn't connected takes a free one;
    /// with no free screen it goes to the main screen.
    public static func mapScreens(_ setup: Setup, connected: [String], main: String) -> [String: String] {
        var map: [String: String] = [:]
        var free = connected.filter { id in !setup.screens.contains { $0.screenID == id } }
        for s in setup.screens {
            if connected.contains(s.screenID) {
                map[s.screenID] = s.screenID
            } else if !free.isEmpty {
                map[s.screenID] = free.removeFirst()
            } else {
                map[s.screenID] = main
            }
        }
        return map
    }

    /// Fills the screen's tiles with windows. Each app's windows take the places it had, in turn.
    /// A tile whose app has no window left closes up.
    public static func assign(_ screen: SetupScreen, windows: [(WindowID, String)]) -> [[WindowID]] {
        var byApp: [String: [WindowID]] = [:]
        for (w, app) in windows { byApp[app, default: []].append(w) }
        var tiles: [[WindowID]] = []
        for tile in screen.tiles {
            var t: [WindowID] = []
            for app in tile {
                if var list = byApp[app], !list.isEmpty {
                    t.append(list.removeFirst())
                    byApp[app] = list
                }
            }
            if !t.isEmpty { tiles.append(t) }
        }
        return tiles
    }

    /// Whether the screen still looks like the setup: the same app showing in each tile.
    public static func matches(_ setup: Setup, current: [String: [[String]]]) -> Bool {
        for s in setup.screens {
            guard let now = current[s.screenID] else { return false }
            let want = s.tiles.compactMap(\.first)
            let have = now.compactMap(\.first)
            if want != have { return false }
        }
        return true
    }
}
