import AppKit
import PanefoldCore

/// The app icon, drawn in code. The same drawing makes the bundle's .icns (scripts/make-icon.swift).
enum AppIcon {
    struct Palette {
        let background: [UInt32]
        let tiles: [UInt32]
    }

    static func palette(_ style: IconStyle) -> Palette {
        switch style {
        case .panefold: Palette(background: [0x1E2A44, 0x0E1424], tiles: [0x5AA9FF, 0x8FD3FF, 0xFFB86B, 0xFF7A85])
        case .ink: Palette(background: [0x111111, 0x000000], tiles: [0xF2F2F2, 0xBDBDBD, 0x8A8A8A, 0x5C5C5C])
        case .sunrise: Palette(background: [0xFFB36B, 0xFF5E7E], tiles: [0xFFFFFF, 0xFFF1DA, 0xFFE1C2, 0xFFD0D8])
        case .mint: Palette(background: [0xD8F6EA, 0x9FE3C8], tiles: [0x1F7A5A, 0x2FA57B, 0x58C79E, 0x0F4F3A])
        case .night: Palette(background: [0x2B1E50, 0x120B26], tiles: [0xB79CFF, 0x7D5CFF, 0xF7A8FF, 0x5D4BB5])
        case .paper: Palette(background: [0xFAF7F0, 0xEDE6D6], tiles: [0x2D2A26, 0xC4492F, 0x6E8B74, 0xD8A23A])
        case .mono: Palette(background: [0xE9EBEF, 0xC9CED6], tiles: [0x3A3F47, 0x5C636E, 0x7E8794, 0xA3ACB8])
        }
    }

    static func image(_ style: IconStyle, size: CGFloat = 512) -> NSImage {
        let p = palette(style)
        return NSImage(size: CGSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width
            let inset = s * 0.09
            let body = rect.insetBy(dx: inset, dy: inset)
            let radius = body.width * 0.225
            let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            NSGradient(colors: p.background.map { NSColor(rgb: $0) })?.draw(in: path, angle: -90)
            // The fold: one tall pane, two stacked beside it, and a sliver of a fourth.
            let pad = body.width * 0.14, gap = body.width * 0.045
            let inner = body.insetBy(dx: pad, dy: pad)
            let half = (inner.width - gap) / 2
            let panes = [
                CGRect(x: inner.minX, y: inner.minY, width: half, height: inner.height),
                CGRect(x: inner.minX + half + gap, y: inner.minY, width: half, height: (inner.height - gap) * 0.58),
                CGRect(x: inner.minX + half + gap, y: inner.minY + (inner.height - gap) * 0.58 + gap, width: half * 0.56, height: (inner.height - gap) * 0.42),
                CGRect(x: inner.minX + half + gap + half * 0.56 + gap, y: inner.minY + (inner.height - gap) * 0.58 + gap, width: half * 0.44 - gap, height: (inner.height - gap) * 0.42),
            ]
            for (i, r) in panes.enumerated() {
                NSColor(rgb: p.tiles[i]).setFill()
                NSBezierPath(roundedRect: r, xRadius: body.width * 0.05, yRadius: body.width * 0.05).fill()
            }
            return true
        }
    }

    /// Shows the chosen icon in the Dock, Finder and Spotlight.
    static func apply(_ style: IconStyle) {
        let img = image(style)
        NSApp.applicationIconImage = img
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }
        NSWorkspace.shared.setIcon(style == .panefold ? nil : img, forFile: path, options: [])
    }
}

/// Checks GitHub for a newer release, at most once a day. Sends nothing about this Mac.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repository = "mralifakbar/panefold"

    @Published private(set) var available: (version: String, url: URL)?
    @Published private(set) var checking = false
    @Published private(set) var lastResult: String?

    func checkIfDue() {
        guard WindowManager.shared.prefs.checkForUpdates else { return }
        let last = Store.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 86400 { check() }
    }

    func check() {
        guard !checking, let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else { return }
        checking = true
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Panefold-Updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (json?["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let page = (json?["html_url"] as? String).flatMap(URL.init(string:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.checking = false
                    Store.set(Date(), forKey: "lastUpdateCheck")
                    if let tag, let page, Self.isNewer(tag, than: SystemState.version) {
                        self.available = (tag, page)
                        self.lastResult = String(localized: "Panefold \(tag) is available")
                    } else {
                        self.available = nil
                        self.lastResult = error == nil ? String(localized: "You have the latest version") : String(localized: "Couldn't check for updates")
                    }
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Reports for "Report a Problem": written on this Mac, read by the user, sent by the user.
@MainActor
enum Feedback {
    static func report(message: String, diagnostics: Bool) -> String {
        var out = """
        \(message)

        ---
        Panefold \(SystemState.version), macOS \(SystemState.macOS)
        """
        guard diagnostics else { return out }
        let wm = WindowManager.shared
        // Apps become letters; window titles are never included.
        var letters: [String: String] = [:]
        func letter(_ bundleID: String) -> String {
            if let l = letters[bundleID] { return l }
            let l = "App " + String(UnicodeScalar(UInt8(65 + letters.count % 26)))
            letters[bundleID] = l
            return l
        }
        out += "\n\(SystemState.isAppleSilicon ? "Apple silicon" : "Intel")\n\nScreens:\n"
        for s in wm.screens {
            let apps = s.tiles.map { t in t.windows.compactMap { wm.tracked[$0].map { letter($0.bundleID) } }.joined(separator: "+") }
            out += "- \(Int(s.display.frame.width))×\(Int(s.display.frame.height)) \(s.kind.rawValue), \(s.capacity) tiles: \(apps.joined(separator: " | "))\n"
        }
        var prefs = wm.prefs
        prefs.floatRules = prefs.floatRules.map { FloatRule(bundleID: letter($0.bundleID), appName: letter($0.bundleID), prefix: "…") }
        prefs.exclusions = ExclusionList()
        prefs.insetsByScreen = [:]
        if let data = try? JSONEncoder().encode(prefs), let json = String(data: data, encoding: .utf8) {
            out += "\nSettings:\n\(json)\n"
        }
        var log = Log.lastHour
        for (bundleID, l) in letters { log = log.replacingOccurrences(of: bundleID, with: l) }
        out += "\nLog (last hour):\n\(log)\n"
        return out
    }

    /// Copies the report and opens a new issue. Nothing goes in the link: the user pastes the report and reads it first.
    static func openIssue(title: String, report: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        var c = URLComponents(string: "https://github.com/\(Updater.repository)/issues/new")!
        c.queryItems = [URLQueryItem(name: "title", value: title)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}
