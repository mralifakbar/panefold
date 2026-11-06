import CoreGraphics
import XCTest
@testable import PanefoldCore

final class ShortcutTests: XCTestCase {
    func testDefaultsUseThePrefix() {
        let b = ShortcutBindings()
        XCTAssertEqual(b.combo(.swapLeft), KeyCombo(KeyCodes.left, [.control, .option]))
        XCTAssertEqual(b.combo(.layoutRows), KeyCombo(KeyCodes.three, [.control, .option, .shift]))
        XCTAssertEqual(b.combo(.count2), KeyCombo(KeyCodes.two, [.control, .option, .command]))
        XCTAssertEqual(b.combo(.tabView), KeyCombo(KeyCodes.tab, .option))
        XCTAssertEqual(b.combo(.previousInStack)?.display(), "⌃⌥⇧`")
        XCTAssertEqual(b.combo(.makePrimary)?.display(), "⌃⌥↩")
    }

    func testNoTwoDefaultsCollideWithAnyPrefix() {
        for prefix in ShortcutPrefix.allCases {
            let b = ShortcutBindings(prefix: prefix)
            let combos = b.all.map(\.1)
            XCTAssertEqual(Set(combos).count, combos.count, "\(prefix)")
        }
    }

    func testPrefixMovesOnlyUnchangedShortcuts() {
        var b = ShortcutBindings()
        b.set(.retile, to: KeyCombo(KeyCodes.r, [.control, .command]))
        b.prefix = .optionCommand
        XCTAssertEqual(b.combo(.retile), KeyCombo(KeyCodes.r, [.control, .command]))
        XCTAssertEqual(b.combo(.float), KeyCombo(KeyCodes.f, [.option, .command]))
        XCTAssertEqual(b.combo(.count3), KeyCombo(KeyCodes.three, [.control, .option, .command]))
    }

    func testCountsChangeTogetherAndCanBeTurnedOff() {
        var b = ShortcutBindings()
        b.set(.count4, to: KeyCombo(KeyCodes.four, [.option, .shift, .command]))
        XCTAssertEqual(b.combo(.count1), KeyCombo(KeyCodes.one, [.option, .shift, .command]))
        XCTAssertTrue(b.isCustom(.count5))
        b.set(.count2, to: nil)
        XCTAssertNil(b.combo(.count5))
        b.reset(.count1)
        XCTAssertEqual(b.combo(.count5), b.defaultCombo(.count5))
    }

    func testConflictsAndSuggestions() {
        let b = ShortcutBindings()
        let taken = KeyCombo(KeyCodes.f, [.control, .option])
        XCTAssertEqual(b.actions(using: taken), [.float])
        XCTAssertEqual(b.actions(using: taken, except: .float), [])
        XCTAssertEqual(b.actions(using: KeyCombo(KeyCodes.tab, [.option, .shift])), [.tabView])
        let free = b.suggestions(for: taken, isTaken: { $0.modifiers == [.option, .command] })
        XCTAssertEqual(free.count, 3)
        XCTAssertFalse(free.contains(taken))
        XCTAssertFalse(free.contains { $0.modifiers == [.option, .command] })
    }

    func testValidity() {
        XCTAssertFalse(KeyCombo(KeyCodes.a, [.shift]).isValidShortcut)
        XCTAssertTrue(KeyCombo(0x69, []).isValidShortcut)
        XCTAssertTrue(KeyCombo(KeyCodes.r, .option).typesCharacter)
        XCTAssertFalse(KeyCombo(KeyCodes.left, .option).typesCharacter)
    }

    func testSystemShortcutsParse() {
        let dict: [String: Any] = [
            "28": ["enabled": true, "value": ["parameters": [51, 20, 1_179_648], "type": "standard"]],
            "29": ["enabled": false, "value": ["parameters": [51, 20, 1_441_792], "type": "standard"]],
            "64": ["enabled": 1, "value": ["parameters": [32, 49, 1_048_576], "type": "standard"]],
        ]
        XCTAssertEqual(SystemShortcuts.parse(dict), [KeyCombo(20, [.shift, .command]), KeyCombo(49, .command)])
    }

    func testCodable() throws {
        var b = ShortcutBindings(prefix: .controlShift)
        b.set(.noPeek, to: KeyCombo(KeyCodes.d, [.control, .command]))
        b.set(.cheatSheet, to: nil)
        let back = try JSONDecoder().decode(ShortcutBindings.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }
}

final class PreferencesTests: XCTestCase {
    func testMissingKeysKeepDefaultsAndValuesAreClamped() throws {
        let json = #"{"gap": 99, "layout": "side", "unknown": 1, "dimAmount": 5, "highlight": "nonsense"}"#
        let p = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(p.gap, 24)
        XCTAssertEqual(p.layout, .side)
        XCTAssertEqual(p.dimAmount, 0.9)
        XCTAssertEqual(p.highlight, .none)
        XCTAssertEqual(p.windowsPerScreen, 3)
        XCTAssertTrue(p.quickActions)
    }

    func testRoundTrip() throws {
        var p = Preferences()
        p.highlightColor = .custom(0x112233)
        p.insetsByScreen["A"] = EdgeInsets(bottom: 80)
        p.floatRules = [FloatRule(bundleID: "com.jetbrains.pycharm", appName: "PyCharm", prefix: "Commit Changes")]
        p.exclusions.exclude("com.example.app", name: "Example")
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p)), p)
    }

    func testBorderNeedsRoom() {
        var p = Preferences()
        p.gap = 0
        p.highlight = .borderAll
        p.borderWidth = 5
        XCTAssertEqual(p.effectiveGap, 6)
        p.highlight = .glowActive
        XCTAssertEqual(p.effectiveGap, 4)
    }

    func testInsets() {
        var p = Preferences()
        p.insetsByScreen["A"] = EdgeInsets(bottom: 80)
        XCTAssertEqual(p.insets(for: "A").apply(to: CGRect(x: 0, y: 0, width: 100, height: 200)), CGRect(x: 0, y: 0, width: 100, height: 120))
        XCTAssertTrue(p.insets(for: "B").isZero)
        p.sameInsetsEverywhere = true
        p.sharedInsets = EdgeInsets(left: 10)
        XCTAssertEqual(p.insets(for: "A"), EdgeInsets(left: 10))
    }
}

final class RulesTests: XCTestCase {
    func testFloatRulesMatchTheFirstTwoWords() {
        XCTAssertEqual(FloatRule.prefix(forTitle: "Push Commits to my_portfolio"), "Push Commits")
        XCTAssertEqual(FloatRule.prefix(forTitle: "my_portfolio – README.md"), "my_portfolio –")
        XCTAssertNil(FloatRule.prefix(forTitle: "   "))
        let rule = FloatRule(bundleID: "com.jetbrains.pycharm", appName: "PyCharm", prefix: "Push Commits")
        XCTAssertTrue(rule.matches(bundleID: "com.jetbrains.pycharm", title: "Push Commits to other_project"))
        XCTAssertFalse(rule.matches(bundleID: "com.jetbrains.pycharm", title: "Push"))
        XCTAssertFalse(rule.matches(bundleID: "com.apple.Safari", title: "Push Commits"))
        XCTAssertFalse(rule.matches(bundleID: "com.jetbrains.pycharm", title: "Pushy Commits"))
    }

    func testExclusionsWithDefaults() {
        var e = ExclusionList()
        XCTAssertTrue(e.isExcluded("com.apple.calculator"))
        e.include("com.apple.calculator")
        XCTAssertFalse(e.isExcluded("com.apple.calculator"))
        e.exclude("com.apple.calculator", name: "Calculator")
        XCTAssertTrue(e.isExcluded("com.apple.calculator"))
        e.exclude("com.tinyspeck.slackmacgap", name: "Slack")
        XCTAssertTrue(e.entries.contains { $0.bundleID == "com.tinyspeck.slackmacgap" && !$0.isDefault })
    }

    func testMinSizeIsLearnedOnlyAfterTwoRefusals() {
        var l = MinSizeLearner()
        let screen = CGSize(width: 1470, height: 900)
        XCTAssertFalse(l.observe(bundleID: "app", requested: CGSize(width: 500, height: 400), actual: CGSize(width: 952, height: 400), screen: screen))
        XCTAssertNil(l.minimum(for: "app"))
        XCTAssertTrue(l.observe(bundleID: "app", requested: CGSize(width: 500, height: 400), actual: CGSize(width: 952, height: 400), screen: screen))
        XCTAssertEqual(l.minimum(for: "app"), CGSize(width: 952, height: 0))
        l.userResized(bundleID: "app", to: CGSize(width: 800, height: 400))
        XCTAssertEqual(l.minimum(for: "app")?.width, 800)
    }

    func testMinSizeIgnoresSlackAndWholeScreenAndNeverLearn() {
        var l = MinSizeLearner()
        let screen = CGSize(width: 1470, height: 900)
        for _ in 0..<2 { l.observe(bundleID: "a", requested: CGSize(width: 500, height: 400), actual: CGSize(width: 505, height: 404), screen: screen) }
        XCTAssertNil(l.minimum(for: "a"))
        for _ in 0..<2 { l.observe(bundleID: "b", requested: CGSize(width: 500, height: 400), actual: CGSize(width: 1400, height: 880), screen: screen) }
        XCTAssertNil(l.minimum(for: "b"))
        l.setNeverLearn("c", true)
        for _ in 0..<2 { l.observe(bundleID: "c", requested: CGSize(width: 500, height: 400), actual: CGSize(width: 900, height: 400), screen: screen) }
        XCTAssertNil(l.minimum(for: "c"))
        // Different answers each time aren't a limit.
        l.observe(bundleID: "d", requested: CGSize(width: 500, height: 400), actual: CGSize(width: 700, height: 400), screen: screen)
        XCTAssertFalse(l.observe(bundleID: "d", requested: CGSize(width: 500, height: 400), actual: CGSize(width: 900, height: 400), screen: screen))
    }
}

final class SetupTests: XCTestCase {
    let setup = Setup(name: "Coding", screens: [
        SetupScreen(screenID: "laptop", screenName: "Built-in", layout: .grid, capacity: 3,
                    tiles: [["com.microsoft.VSCode"], ["com.apple.Terminal"], ["com.apple.Safari", "com.apple.Notes"]]),
        SetupScreen(screenID: "monitor", screenName: "Studio Display", layout: .columns, capacity: 2,
                    tiles: [["com.apple.Safari"], ["com.apple.Safari"]]),
    ])

    func testScreensMapToConnectedOnes() {
        XCTAssertEqual(SetupPlanner.mapScreens(setup, connected: ["laptop", "monitor"], main: "laptop"), ["laptop": "laptop", "monitor": "monitor"])
        XCTAssertEqual(SetupPlanner.mapScreens(setup, connected: ["laptop", "other"], main: "laptop"), ["laptop": "laptop", "monitor": "other"])
        XCTAssertEqual(SetupPlanner.mapScreens(setup, connected: ["laptop"], main: "laptop"), ["laptop": "laptop", "monitor": "laptop"])
    }

    func testWindowsFillTheirAppsPlacesInTurn() {
        let tiles = SetupPlanner.assign(setup.screens[1], windows: [(10, "com.apple.Safari"), (11, "com.apple.Safari")])
        XCTAssertEqual(tiles, [[10], [11]])
        // Only one Safari window: that tile closes up.
        XCTAssertEqual(SetupPlanner.assign(setup.screens[1], windows: [(10, "com.apple.Safari")]), [[10]])
        let laptop = SetupPlanner.assign(setup.screens[0], windows: [(1, "com.apple.Notes"), (2, "com.microsoft.VSCode"), (3, "com.apple.Safari")])
        XCTAssertEqual(laptop, [[2], [3, 1]])
    }

    func testMatching() {
        XCTAssertTrue(SetupPlanner.matches(setup, current: [
            "laptop": [["com.microsoft.VSCode"], ["com.apple.Terminal"], ["com.apple.Safari"]],
            "monitor": [["com.apple.Safari"], ["com.apple.Safari"]],
        ]))
        XCTAssertFalse(SetupPlanner.matches(setup, current: ["laptop": [["com.apple.Terminal"]]]))
        XCTAssertEqual(setup.apps, ["com.microsoft.VSCode", "com.apple.Terminal", "com.apple.Safari", "com.apple.Notes"])
    }
}

final class ActivityTests: XCTestCase {
    func testCountsAndWeek() {
        var log = ActivityLog()
        let now = Date()
        log.record(.placed, on: now)
        log.record(.shortcut, detail: "swapLeft", on: now)
        log.record(.commandDrag, on: now)
        log.record(.drag, on: now.addingTimeInterval(-86400))
        log.record(.placed, on: now.addingTimeInterval(-10 * 86400))
        let week = log.week(ending: now)
        XCTAssertEqual(week.placed, 1)
        XCTAssertEqual(week.keyboardTotal, 1.5)
        XCTAssertEqual(week.mouseTotal, 1.5)
        XCTAssertEqual(ActivityLog.timeSaved(week), 6 + 3 * 3)
        let fav = ActivityLog.favorites(week, suggestions: ["swapLeft", "focusMode"])
        XCTAssertEqual(fav.mostUsed, "swapLeft")
        XCTAssertEqual(fav.tryNext, "focusMode")
    }

    func testHoverFocusWaitsAndIgnoresTyping() {
        var h = HoverFocusPolicy()
        XCTAssertNil(h.pointer(x: 0, y: 0, over: 2, active: 1, buttonsDown: false, at: 0))
        XCTAssertNil(h.pointer(x: 0, y: 0, over: 2, active: 1, buttonsDown: false, at: 0.1))
        XCTAssertEqual(h.pointer(x: 0, y: 0, over: 2, active: 1, buttonsDown: false, at: 0.2), 2)
        // While typing, a pointer resting on another window doesn't take focus.
        h.keyPressed(at: 1)
        XCTAssertNil(h.pointer(x: 0, y: 0, over: 3, active: 2, buttonsDown: false, at: 1.1))
        XCTAssertNil(h.pointer(x: 0, y: 0, over: 3, active: 2, buttonsDown: false, at: 2))
        // Moving the pointer brings hovering back; a held button pauses it.
        XCTAssertNil(h.pointer(x: 50, y: 0, over: 3, active: 2, buttonsDown: true, at: 2.1))
        XCTAssertNil(h.pointer(x: 50, y: 0, over: 3, active: 2, buttonsDown: false, at: 2.2))
        XCTAssertEqual(h.pointer(x: 50, y: 0, over: 3, active: 2, buttonsDown: false, at: 2.5), 3)
    }
}
