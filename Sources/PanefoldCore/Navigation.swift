import CoreGraphics

public enum Direction: String, CaseIterable, Codable, Sendable {
    case left, right, up, down

    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
}

public enum Navigator {
    /// The rect next to `source` in `direction`: the nearest one that shares some of its edge.
    /// Ties go to the top (for left and right) or the left (for up and down), so from the primary
    /// window → reaches the top of the right-hand column.
    public static func neighbor<ID>(of source: CGRect, in candidates: [(ID, CGRect)], direction: Direction, tolerance: CGFloat = 24) -> ID? {
        let ahead = candidates.filter { _, r in
            switch direction {
            case .right: r.midX > source.maxX - tolerance && r.minX >= source.midX
            case .left: r.midX < source.minX + tolerance && r.maxX <= source.midX
            case .down: r.midY > source.maxY - tolerance && r.minY >= source.midY
            case .up: r.midY < source.minY + tolerance && r.maxY <= source.midY
            }
        }
        guard !ahead.isEmpty else { return nil }
        func distance(_ r: CGRect) -> CGFloat {
            switch direction {
            case .right: max(0, r.minX - source.maxX)
            case .left: max(0, source.minX - r.maxX)
            case .down: max(0, r.minY - source.maxY)
            case .up: max(0, source.minY - r.maxY)
            }
        }
        func overlap(_ r: CGRect) -> CGFloat {
            direction.axis == .horizontal
                ? min(r.maxY, source.maxY) - max(r.minY, source.minY)
                : min(r.maxX, source.maxX) - max(r.minX, source.minX)
        }
        let overlapping = ahead.filter { overlap($0.1) > 0 }
        let pool = overlapping.isEmpty ? ahead : overlapping
        let nearest = pool.map { distance($0.1) }.min() ?? 0
        let closest = pool.filter { distance($0.1) <= nearest + tolerance }
        return closest.min { a, b in
            if overlapping.isEmpty {
                let pa = perpendicularOffset(a.1, source, direction), pb = perpendicularOffset(b.1, source, direction)
                if pa != pb { return pa < pb }
            }
            return direction.axis == .horizontal ? a.1.minY < b.1.minY : a.1.minX < b.1.minX
        }?.0
    }

    static func perpendicularOffset(_ r: CGRect, _ s: CGRect, _ d: Direction) -> CGFloat {
        d.axis == .horizontal ? abs(r.midY - s.midY) : abs(r.midX - s.midX)
    }

    /// The candidate closest to `source` in `direction`, by centers. Used by the window picker,
    /// where windows can be anywhere.
    public static func nearest<ID>(from source: CGRect, in candidates: [(ID, CGRect)], direction: Direction) -> ID? {
        let s = CGPoint(x: source.midX, y: source.midY)
        return candidates.compactMap { id, r -> (ID, CGFloat)? in
            let dx = r.midX - s.x, dy = r.midY - s.y
            let along: CGFloat, across: CGFloat
            switch direction {
            case .right: (along, across) = (dx, abs(dy))
            case .left: (along, across) = (-dx, abs(dy))
            case .down: (along, across) = (dy, abs(dx))
            case .up: (along, across) = (-dy, abs(dx))
            }
            guard along > 1 else { return nil }
            return (id, along + across * 2)
        }.min { $0.1 < $1.1 }?.0
    }
}
