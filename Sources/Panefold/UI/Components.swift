import AppKit
import SwiftUI
import PanefoldCore

/// A small picture of a layout, drawn by the same engine that places windows.
struct LayoutPicture: View {
    let kind: LayoutKind
    var shape: ScreenShape = .standard
    var count = 3
    var mainSize: MainSize = .half
    var selected = false

    var body: some View {
        GeometryReader { geo in
            let area = CGRect(origin: .zero, size: geo.size)
            let frames = Self.frames(kind, shape: shape, count: count, mainSize: mainSize, area: area, gap: 2)
            ZStack(alignment: .topLeading) {
                ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == 0 ? (selected ? Color.accentColor : Color.primary.opacity(0.55)) : (selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.28)))
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                }
            }
        }
    }

    static func frames(_ kind: LayoutKind, shape: ScreenShape, count: Int, mainSize: MainSize, area: CGRect, gap: CGFloat) -> [CGRect] {
        let n = min(count, LayoutBuilder.hardLimit(kind, shape: shape))
        guard let tree = LayoutBuilder.tree(kind, count: n, shape: shape) else { return [] }
        let children: Int = if case .split(_, let c) = tree { c.count } else { 1 }
        var engine = LayoutEngine(area: area, gap: gap, tree: tree,
                                  rootWeights: LayoutBuilder.rootWeights(kind, count: n, shape: shape, mainSize: mainSize, children: children))
        engine.floor = .zero
        let r = engine.layout()
        return (0..<n).compactMap { r.frames[$0] }
    }
}

struct StatusDot: View {
    let status: TilingStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    var color: Color {
        switch status {
        case .tiling, .focusMode: .green
        case .pausedForStageManager, .waitingForSetup: .orange
        case .off: .gray
        case .needsAccess: .red
        }
    }
}

extension TilingStatus {
    var text: String {
        switch self {
        case .tiling(let n): n == 1 ? String(localized: "Tiling 1 window") : String(localized: "Tiling \(n) windows")
        case .focusMode(let n): String(localized: "Focus mode · \(n) windows")
        case .pausedForStageManager: String(localized: "Paused while Stage Manager is on")
        case .waitingForSetup: String(localized: "Waiting for setup to finish")
        case .off: String(localized: "Automatic tiling is off")
        case .needsAccess: String(localized: "Needs Accessibility access")
        }
    }
}

/// A miniature of a screen with each tile's app icon where it sits.
struct ScreenPreview: View {
    let screen: ScreenSnapshot
    @EnvironmentObject var wm: WindowManager

    var body: some View {
        GeometryReader { geo in
            let frame = screen.display.frame
            let scale = min(geo.size.width / frame.width, geo.size.height / frame.height)
            let size = CGSize(width: frame.width * scale, height: frame.height * scale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                ForEach(Array(screen.tiles.enumerated()), id: \.offset) { i, tile in
                    if let f = screen.tileFrames[safe: i] {
                        let zoomed = screen.zoomed == tile.showing
                        let r = zoomed ? CGRect(x: 6 / scale, y: 6 / scale, width: frame.width - 12 / scale, height: frame.height - 12 / scale)
                            : f.offsetBy(dx: -frame.minX, dy: -frame.minY)
                        let active = tile.windows.contains(wm.activeWindow ?? 0)
                        tileView(tile, active: active, zoomed: zoomed, dimmed: screen.zoomed != nil && !zoomed)
                            .frame(width: r.width * scale, height: r.height * scale)
                            .offset(x: r.minX * scale, y: r.minY * scale)
                            .zIndex(zoomed ? 1 : 0)
                    }
                }
                if screen.tiles.isEmpty {
                    Text("No windows here yet").font(.caption).foregroundStyle(.secondary)
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tileView(_ tile: Tile, active: Bool, zoomed: Bool, dimmed: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(active ? 0.16 : 0.09))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.5))
            if let icon = wm.appIcon(tile.showing) {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if zoomed {
                Text("Focus").font(.caption2.bold()).padding(.horizontal, 4).background(Color.accentColor, in: Capsule()).foregroundStyle(.white).padding(4)
            } else if tile.isStacked {
                Text("\(tile.windows.count)").font(.caption2.bold()).padding(.horizontal, 5).background(Color.orange, in: Capsule()).foregroundStyle(.white).padding(4)
            }
        }
        .opacity(dimmed ? 0.35 : 1)
    }
}

/// A row with an icon, a title and a trailing control: the panel's building block.
struct PanelRow<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 26)
    }
}

/// A key combination drawn like keycaps.
struct KeyCaps: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// A card under the status with something that needs doing.
struct ActionCard: View {
    let symbol: String
    let tint: Color
    let text: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let button { Button(button, action: action).controlSize(.small).buttonStyle(.borderedProminent) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.1)))
    }
}
