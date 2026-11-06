import CoreGraphics
import XCTest
@testable import PanefoldCore

final class TileSetTests: XCTestCase {
    func testWindowsTakeTilesInOrderThenStackInTheActiveTile() {
        var t = TileSet(capacity: 3)
        XCTAssertEqual(t.insert(1, active: nil), .newTile(0))
        XCTAssertEqual(t.insert(2, active: 1), .newTile(1))
        XCTAssertEqual(t.insert(3, active: 2), .newTile(2))
        XCTAssertEqual(t.insert(4, active: 2), .stacked(tile: 1))
        XCTAssertEqual(t.showing, [1, 4, 3])
        XCTAssertEqual(t.tiles[1].windows, [4, 2])
        XCTAssertEqual(t.insert(4, active: 1), .alreadyThere)
    }

    func testFloatInTheMiddleWhenFull() {
        var t = TileSet(capacity: 2)
        t.insert(1, active: nil)
        t.insert(2, active: nil)
        XCTAssertEqual(t.insert(3, active: 1, whenFull: .floatInMiddle), .overflowed)
        XCTAssertEqual(t.overflow, [3])
        // When a tiled window closes, the waiting one joins.
        t.remove(1)
        XCTAssertEqual(t.showing, [2, 3])
        XCTAssertTrue(t.overflow.isEmpty)
    }

    func testMainTilePushesTheOldestBehindTheLastTile() {
        var t = TileSet(capacity: 2)
        t.insert(1, active: nil, placement: .mainTile)
        t.insert(2, active: nil, placement: .mainTile)
        XCTAssertEqual(t.showing, [2, 1])
        t.insert(3, active: nil, placement: .mainTile)
        XCTAssertEqual(t.showing, [3, 2])
        XCTAssertEqual(t.tiles[1].windows, [2, 1])
    }

    func testClosingTheShowingWindowBringsForwardTheMostRecent() {
        var t = TileSet(capacity: 1)
        t.insert(1, active: nil)
        t.insert(2, active: 1)
        t.insert(3, active: 2)
        XCTAssertEqual(t.tiles[0].windows, [3, 2, 1])
        t.remove(3)
        XCTAssertEqual(t.tiles[0].showing, 2)
    }

    func testCycleThroughAStack() {
        var t = TileSet(capacity: 1)
        [1, 2, 3].forEach { t.insert($0, active: 1) }
        XCTAssertEqual(t.cycle(tileOf: 3, forward: true), 2)
        XCTAssertEqual(t.cycle(tileOf: 2, forward: true), 1)
        XCTAssertEqual(t.cycle(tileOf: 1, forward: false), 2)
        var single = TileSet(capacity: 1, tiles: [Tile([9])])
        XCTAssertNil(single.cycle(tileOf: 9, forward: true))
    }

    func testLoweringTheCountStacksTheLastTileRaisingGivesItBack() {
        var t = TileSet(capacity: 3)
        [1, 2, 3].forEach { t.insert($0, active: nil) }
        t.setCapacity(2)
        XCTAssertEqual(t.showing, [1, 2])
        XCTAssertEqual(t.tiles[1].windows, [2, 3])
        t.setCapacity(3)
        XCTAssertEqual(t.showing, [1, 2, 3])
        t.setCapacity(1, whenFull: .floatInMiddle)
        XCTAssertEqual(t.overflow, [2, 3])
    }

    func testSwapMovesOnlyTheShowingWindows() {
        var t = TileSet(capacity: 2)
        t.insert(1, active: nil)
        t.insert(2, active: nil)
        t.insert(3, active: 2)
        XCTAssertTrue(t.swap(1, 3))
        XCTAssertEqual(t.tiles[0].windows, [3])
        XCTAssertEqual(t.tiles[1].windows, [1, 2])
        XCTAssertTrue(t.makePrimary(1))
        XCTAssertEqual(t.showing, [1, 3])
        XCTAssertFalse(t.makePrimary(1))
    }

    func testStackOntoAnotherTileAndPlace() {
        var t = TileSet(capacity: 3)
        [1, 2, 3].forEach { t.insert($0, active: nil) }
        XCTAssertTrue(t.stack(3, onto: 1))
        XCTAssertEqual(t.tiles.count, 2)
        XCTAssertEqual(t.tiles[0].windows, [3, 1])
        XCTAssertTrue(t.place(1, inTile: 1))
        XCTAssertEqual(t.tiles[1].windows, [1, 2])
    }

    func testRetainDropsGoneWindows() {
        var t = TileSet(capacity: 2)
        [1, 2, 3].forEach { t.insert($0, active: 1) }
        t.retain([2, 3])
        XCTAssertEqual(t.allTiled.sorted(), [2, 3])
    }

    func testCodableRoundTrip() throws {
        var t = TileSet(capacity: 3)
        [7, 8, 9, 10].forEach { t.insert($0, active: 8) }
        let back = try JSONDecoder().decode(TileSet.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }
}

final class PlannerTests: XCTestCase {
    let geometry = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), area: CGRect(x: 0, y: 32, width: 1512, height: 900))

    func testStackedWindowsShareTheirTileAndFocusFillsTheScreen() {
        var space = ScreenSpace(capacity: 2)
        [1, 2, 3].forEach { space.tiles.insert($0, active: 2) }
        var prefs = Preferences()
        prefs.gap = 8
        var plan = Planner.plan(space, prefs: prefs, geometry: geometry) { _ in nil }
        XCTAssertEqual(plan.frames[2], plan.frames[3])
        XCTAssertEqual(plan.tileFrames.count, 2)
        space.zoomed = 3
        plan = Planner.plan(space, prefs: prefs, geometry: geometry) { _ in nil }
        XCTAssertEqual(plan.frames[3], geometry.area.insetBy(dx: 8, dy: 8))
    }

    func testScreenPickWinsAndSizesStayWithPositions() {
        var space = ScreenSpace(capacity: 3)
        [1, 2].forEach { space.tiles.insert($0, active: nil) }
        space.layoutPick = .rows
        var prefs = Preferences()
        prefs.gap = 0
        XCTAssertEqual(Planner.shape(of: space, prefs: prefs, geometry: geometry).kind, .rows)
        space.setOverrides(["": [0.75, 0.25]], kind: .rows, count: 2)
        let plan = Planner.plan(space, prefs: prefs, geometry: geometry) { _ in nil }
        XCTAssertEqual(plan.frames[1]?.height, 675)
        space.tiles.swap(1, 2)
        XCTAssertEqual(Planner.plan(space, prefs: prefs, geometry: geometry) { _ in nil }.frames[2]?.height, 675)
    }

    func testUnfitWindowsAreReported() {
        var space = ScreenSpace(capacity: 3)
        [1, 2, 3].forEach { space.tiles.insert($0, active: nil) }
        let plan = Planner.plan(space, prefs: Preferences(), geometry: geometry) { $0 == 3 ? CGSize(width: 1000, height: 800) : nil }
        XCTAssertEqual(plan.unfit, [3])
    }

    func testCenteredFloat() {
        let r = Planner.centered(in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(r, CGRect(x: 200, y: 150, width: 600, height: 700))
    }
}
