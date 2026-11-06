import CoreGraphics
import XCTest
@testable import PanefoldCore

final class LayoutTests: XCTestCase {
    let laptop = CGRect(x: 0, y: 25, width: 1470, height: 900)
    let monitor = CGRect(x: 0, y: 25, width: 1920, height: 1030)
    let ultrawide = CGRect(x: 0, y: 25, width: 3440, height: 1390)

    func frames(_ kind: LayoutKind, _ n: Int, area: CGRect, shape: ScreenShape = .standard, main: MainSize = .half, gap: CGFloat = 0,
                overrides: [String: [Double]] = [:], mins: [Int: CGSize] = [:]) -> LayoutResult {
        let tree = LayoutBuilder.tree(kind, count: n, shape: shape)!
        let children: Int = if case .split(_, let c) = tree { c.count } else { 1 }
        return LayoutEngine(area: area, gap: gap, tree: tree,
                            rootWeights: LayoutBuilder.rootWeights(kind, count: n, shape: shape, mainSize: main, children: children),
                            overrides: overrides, minSizes: mins).layout()
    }

    func testShapeOfScreens() {
        XCTAssertEqual(ScreenShape(size: CGSize(width: 1512, height: 982)), .standard)
        XCTAssertEqual(ScreenShape(size: CGSize(width: 3440, height: 1440)), .ultrawide)
        XCTAssertEqual(ScreenShape(size: CGSize(width: 1080, height: 1920)), .vertical)
    }

    func testOneWindowFillsTheArea() {
        let r = frames(.grid, 1, area: laptop, gap: 8)
        XCTAssertEqual(r.frames[0], laptop.insetBy(dx: 8, dy: 8))
    }

    func testGridFoldsEachNewWindowIntoHalfOfTheNewestSpace() {
        let two = frames(.grid, 2, area: laptop)
        XCTAssertEqual(two.frames[0], CGRect(x: 0, y: 25, width: 735, height: 900))
        XCTAssertEqual(two.frames[1], CGRect(x: 735, y: 25, width: 735, height: 900))

        let three = frames(.grid, 3, area: laptop)
        XCTAssertEqual(three.frames[0]?.height, 900)
        XCTAssertEqual(three.frames[1], CGRect(x: 735, y: 25, width: 735, height: 450))
        XCTAssertEqual(three.frames[2], CGRect(x: 735, y: 475, width: 735, height: 450))

        // Four: the primary gives the bottom of its column to the fourth window.
        let four = frames(.grid, 4, area: laptop)
        XCTAssertEqual(four.frames[0]?.origin, CGPoint(x: 0, y: 25))
        XCTAssertEqual(four.frames[3]?.origin, CGPoint(x: 0, y: 475))
        XCTAssertEqual(four.frames[1]?.origin, CGPoint(x: 735, y: 25))
        XCTAssertEqual(four.frames[2]?.origin, CGPoint(x: 735, y: 475))
    }

    func testGapsSeparateTilesAndEdges() {
        let r = frames(.columns, 2, area: CGRect(x: 0, y: 0, width: 1000, height: 500), gap: 10)
        XCTAssertEqual(r.frames[0], CGRect(x: 10, y: 10, width: 485, height: 480))
        XCTAssertEqual(r.frames[1], CGRect(x: 505, y: 10, width: 485, height: 480))
    }

    func testFramesNeverOverlapAndStayInside() {
        for kind in LayoutKind.allCases {
            for shape in [ScreenShape.standard, .ultrawide, .vertical] {
                let area = shape == .vertical ? CGRect(x: 0, y: 0, width: 1080, height: 1890) : (shape == .ultrawide ? ultrawide : monitor)
                for n in 1...LayoutBuilder.hardLimit(kind, shape: shape) {
                    let r = frames(kind, n, area: area, shape: shape, gap: 8)
                    let rects = Array(r.frames.values)
                    XCTAssertEqual(rects.count, n, "\(kind) \(shape) \(n)")
                    for (i, a) in rects.enumerated() {
                        XCTAssertTrue(area.contains(a), "\(kind) \(shape) \(n) \(a)")
                        for b in rects[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(kind) \(shape) \(n)") }
                    }
                }
            }
        }
    }

    func testMainWindowSize() {
        let r = frames(.grid, 3, area: CGRect(x: 0, y: 0, width: 1500, height: 900), main: .twoThirds)
        XCTAssertEqual(r.frames[0]?.width, 1000)
        let cols = frames(.columns, 3, area: CGRect(x: 0, y: 0, width: 2000, height: 900), main: .sixty)
        XCTAssertEqual(cols.frames[0]?.width, 1200)
        XCTAssertEqual(cols.frames[1]?.width, 400)
        // A screen that can't spare that much gives the main window as much as fits.
        let small = frames(.columns, 3, area: CGRect(x: 0, y: 0, width: 1000, height: 900), main: .sixty)
        XCTAssertEqual(small.frames[0]?.width, 400)
        let rows = frames(.rows, 2, area: CGRect(x: 0, y: 0, width: 1000, height: 1000), main: .sixty)
        XCTAssertEqual(rows.frames[0]?.height, 600)
    }

    func testHalfMeansEqualSharesInColumns() {
        let r = frames(.columns, 3, area: CGRect(x: 0, y: 0, width: 1200, height: 900))
        XCTAssertEqual(r.frames.values.map(\.width).sorted(), [400, 400, 400])
    }

    func testUltrawideSideKeepsTwoBigWindowsAndANarrowColumn() {
        let r = frames(.side, 5, area: CGRect(x: 0, y: 0, width: 3440, height: 1400), shape: .ultrawide)
        XCTAssertEqual(r.frames[0]?.width, 1290)
        XCTAssertEqual(r.frames[1]?.width, 1290)
        XCTAssertEqual(r.frames[2]?.width, 860)
        XCTAssertEqual(r.frames[2]?.minX, 2580)
        XCTAssertEqual(r.frames[4]?.maxY, 1400)
    }

    func testVerticalLayouts() {
        let area = CGRect(x: 0, y: 0, width: 1080, height: 1900)
        XCTAssertEqual(LayoutBuilder.effectiveKind(.grid, shape: .vertical, pickedForScreen: false), .rows)
        XCTAssertEqual(LayoutBuilder.effectiveKind(.columns, shape: .vertical, pickedForScreen: true), .rows)
        let grid = frames(.grid, 3, area: area, shape: .vertical)
        XCTAssertEqual(grid.frames[0], CGRect(x: 0, y: 0, width: 1080, height: 950))
        XCTAssertEqual(grid.frames[1]?.width, 540)
        let side = frames(.side, 5, area: area, shape: .vertical)
        XCTAssertEqual(side.frames[0]?.minY, 0)
        XCTAssertEqual(side.frames[0]?.width, 1080)
        XCTAssertEqual(side.frames.count, 5)
    }

    func testDistributeHonorsMinimums() {
        XCTAssertEqual(LayoutEngine.distribute(total: 1000, weights: [0.5, 0.5], mins: [700, 0]), [700, 300])
        XCTAssertEqual(LayoutEngine.distribute(total: 999, weights: [1, 1, 1], mins: [0, 0, 0]).reduce(0, +), 999)
        // More than fits: proportional, and the result reports it.
        XCTAssertEqual(LayoutEngine.distribute(total: 100, weights: [0.5, 0.5], mins: [80, 80]), [50, 50])
    }

    func testAppThatWontShrinkGetsRoomOrIsUnfit() {
        // An app needing 952 points opens first on a 1470-point screen: it keeps 952, the next window gets the rest.
        let r = frames(.grid, 2, area: laptop, mins: [0: CGSize(width: 952, height: 732)])
        XCTAssertEqual(r.frames[0]?.width, 952)
        XCTAssertEqual(r.frames[1]?.width, 518)
        XCTAssertTrue(r.unfit.isEmpty)
        // Opened third instead, it can't fit under the window above it.
        let third = frames(.grid, 3, area: laptop, mins: [2: CGSize(width: 952, height: 732)])
        XCTAssertEqual(third.unfit, [2])
    }

    func testCapacityOnALaptopAndAMonitor() {
        XCTAssertEqual(Capacity.fitting(4, kind: .grid, shape: .standard, area: laptop, gap: 8, mainSize: .half), 4)
        XCTAssertEqual(Capacity.fitting(4, kind: .columns, shape: .standard, area: laptop, gap: 8, mainSize: .half), 3)
        XCTAssertEqual(Capacity.fitting(4, kind: .columns, shape: .standard, area: monitor, gap: 8, mainSize: .half), 4)
        XCTAssertEqual(Capacity.fitting(4, kind: .rows, shape: .standard, area: CGRect(x: 0, y: 0, width: 1470, height: 850), gap: 8, mainSize: .half), 2)
        XCTAssertEqual(Capacity.fitting(4, kind: .rows, shape: .standard, area: CGRect(x: 0, y: 0, width: 1920, height: 980), gap: 8, mainSize: .half), 3)
        XCTAssertEqual(Capacity.fitting(4, kind: .side, shape: .standard, area: CGRect(x: 0, y: 0, width: 1470, height: 850), gap: 8, mainSize: .half), 3)
        XCTAssertEqual(Capacity.fitting(5, kind: .side, shape: .ultrawide, area: ultrawide, gap: 8, mainSize: .half), 5)
        XCTAssertEqual(Capacity.fitting(5, kind: .grid, shape: .standard, area: monitor, gap: 8, mainSize: .half), 4)
        XCTAssertEqual(Capacity.issue(count: 3, kind: .grid, shape: .standard, area: laptop, gap: 8, mainSize: .half,
                                      minSizes: [2: CGSize(width: 952, height: 800)]), .appNeedsRoom(tile: 2))
    }
}

final class ResizeTests: XCTestCase {
    func layout(_ kind: LayoutKind, _ n: Int, overrides: [String: [Double]] = [:]) -> LayoutResult {
        let tree = LayoutBuilder.tree(kind, count: n, shape: .standard)!
        let children: Int = if case .split(_, let c) = tree { c.count } else { 1 }
        return LayoutEngine(area: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 0, tree: tree,
                            rootWeights: LayoutBuilder.rootWeights(kind, count: n, shape: .standard, mainSize: .half, children: children),
                            overrides: overrides).layout()
    }

    func testDraggingASharedEdgeMovesTheNeighbor() {
        let r = layout(.grid, 3)
        let old = r.frames[0]!
        var new = old
        new.size.width += 100
        let updates = Resizer.weightsAfterDrag(r, leaf: 0, old: old, new: new, gap: 0)
        XCTAssertEqual(updates[""], [0.6, 0.4])
        let after = layout(.grid, 3, overrides: updates)
        XCTAssertEqual(after.frames[0]?.width, 600)
        XCTAssertEqual(after.frames[1]?.minX, 600)
    }

    func testDraggingAnInnerEdge() {
        let r = layout(.grid, 3)
        let old = r.frames[2]!
        var new = old
        new.origin.y -= 200
        new.size.height += 200
        let updates = Resizer.weightsAfterDrag(r, leaf: 2, old: old, new: new, gap: 0)
        XCTAssertEqual(updates["/1"], [0.25, 0.75])
        XCTAssertNil(updates[""])
    }

    func testOuterEdgesDontMove() {
        let r = layout(.grid, 2)
        let old = r.frames[0]!
        var new = old
        new.origin.x += 50
        new.size.width -= 50
        XCTAssertTrue(Resizer.weightsAfterDrag(r, leaf: 0, old: old, new: new, gap: 0).isEmpty)
    }

    func testStepGrowsAlongBothAxesAndStopsAtTheLimit() {
        let r = layout(.grid, 4)
        let grown = Resizer.weightsAfterStep(r, leaf: 0, delta: 50)!
        XCTAssertEqual(grown[""]?.first ?? 0, 0.55, accuracy: 0.001)
        XCTAssertEqual(grown["/0"]?.first ?? 0, 0.5625, accuracy: 0.001)
        XCTAssertNil(Resizer.weightsAfterStep(layout(.grid, 1), leaf: 0, delta: 50))
    }
}

final class NavigationTests: XCTestCase {
    func testFromThePrimaryRightGoesToTheTopOfTheColumn() {
        let rects: [(Int, CGRect)] = [
            (1, CGRect(x: 500, y: 0, width: 500, height: 400)),
            (2, CGRect(x: 500, y: 400, width: 500, height: 400)),
        ]
        let primary = CGRect(x: 0, y: 0, width: 500, height: 800)
        XCTAssertEqual(Navigator.neighbor(of: primary, in: rects, direction: .right), 1)
        XCTAssertNil(Navigator.neighbor(of: primary, in: rects, direction: .left))
        XCTAssertEqual(Navigator.neighbor(of: rects[0].1, in: rects + [(0, primary)], direction: .down), 2)
        XCTAssertEqual(Navigator.neighbor(of: rects[1].1, in: rects + [(0, primary)], direction: .left), 0)
    }

    func testScreensSideBySide() {
        let screens: [(String, CGRect)] = [("ext", CGRect(x: 1470, y: -200, width: 1920, height: 1080))]
        XCTAssertEqual(Navigator.neighbor(of: CGRect(x: 0, y: 0, width: 1470, height: 956), in: screens, direction: .right), "ext")
    }

    func testNearestByCenter() {
        let items: [(Int, CGRect)] = [(1, CGRect(x: 300, y: 0, width: 100, height: 100)), (2, CGRect(x: 300, y: 600, width: 100, height: 100))]
        XCTAssertEqual(Navigator.nearest(from: CGRect(x: 0, y: 0, width: 100, height: 100), in: items, direction: .right), 1)
        XCTAssertEqual(Navigator.nearest(from: CGRect(x: 0, y: 0, width: 100, height: 100), in: items, direction: .down), 2)
    }
}
