import XCTest

/// Shared driver for the end-to-end flows (docs/streams/ios-e2e.md): the REAL core (network, mpv
/// `ao=audiounit` at volume 0), driven through the UI like a user, with the app's `e2e-state`
/// probe (App/E2EProbe.swift) as the oracle for what the core is doing.
class E2ECase: XCTestCase {
    var app: XCUIApplication!
    private var started = Date()

    override func setUp() {
        continueAfterFailure = false
        started = Date()
        app = XCUIApplication()
    }

    override func tearDown() {
        let secs = Date().timeIntervalSince(started)
        let ok = (testRun?.totalFailureCount ?? 1) == 0
        if !ok, let app {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "failure-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
            if let dir = ProcessInfo.processInfo.environment["E2E_SHOTS"] {
                let file = URL(fileURLWithPath: dir).appendingPathComponent("\(flowName).png")
                try? app.screenshot().pngRepresentation.write(to: file)
            }
        }
        print(String(format: "E2E_RESULT %@ %@ %.1fs", flowName, ok ? "PASS" : "FAIL", secs))
        app?.terminate()
    }

    var flowName: String {
        name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? name
    }

    // MARK: launching

    /// `reset`: a fresh user (empty database). `onboarding`: let the first-run import offer show.
    func launch(reset: Bool = false, onboarding: Bool = false, deeplink: String? = nil, extra: [String] = []) {
        var args = ["-e2e", "YES", "-volume", "0", "-traceAudio", "YES"]
        if reset { args += ["-e2eReset", "YES"] }
        if !onboarding { args += ["-uitest"] }
        if let deeplink { args += ["-deeplink", deeplink] }
        app.launchArguments = args + extra
        app.launch()
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "app should come up with the e2e probe")
    }

    func relaunch(deeplink: String? = nil) {
        app.terminate()
        launch(deeplink: deeplink)
    }

    // MARK: the oracle

    var probe: XCUIElement { app.descendants(matching: .any)["e2e-state"].firstMatch }

    struct State {
        let raw: [String: Any]
        var id: String { raw["id"] as? String ?? "" }
        var title: String { raw["title"] as? String ?? "" }
        var pos: Double { (raw["pos"] as? NSNumber)?.doubleValue ?? 0 }
        var dur: Double { (raw["dur"] as? NSNumber)?.doubleValue ?? 0 }
        var paused: Bool { raw["paused"] as? Bool ?? true }
        var shuffle: Bool { raw["shuffle"] as? Bool ?? false }
        var repeatMode: String { raw["repeat"] as? String ?? "" }
        var qi: Int { (raw["qi"] as? NSNumber)?.intValue ?? -1 }
        var q: [String] { raw["q"] as? [String] ?? [] }
        var qt: [String] { raw["qt"] as? [String] ?? [] }
        /// Upcoming rows Autoplay brought in.
        var auto: Int { (raw["auto"] as? NSNumber)?.intValue ?? 0 }
        var src: String { raw["src"] as? String ?? "" }
        var srcId: String { raw["srcId"] as? String ?? "" }
        var smart: Bool { raw["smart"] as? Bool ?? false }
        var recs: Int { (raw["recs"] as? NSNumber)?.intValue ?? 0 }
        var speed: Double { (raw["speed"] as? NSNumber)?.doubleValue ?? 1 }
        var sleep: String { raw["sleep"] as? String ?? "" }
        var liked: [String] { raw["liked"] as? [String] ?? [] }
        var saved: [String] { raw["saved"] as? [String] ?? [] }
        var follows: [String] { raw["follows"] as? [String] ?? [] }
        var playlists: [[String: Any]] { raw["playlists"] as? [[String: Any]] ?? [] }
        var mfy: Int { (raw["mfy"] as? NSNumber)?.intValue ?? 0 }
        var explicitFilter: Bool { raw["explicitFilter"] as? Bool ?? false }
        var normalize: Bool { raw["normalize"] as? Bool ?? false }
        var crossfade: Int { (raw["crossfade"] as? NSNumber)?.intValue ?? -1 }
        var eq: String { raw["eq"] as? String ?? "" }
        var eqOn: Bool { raw["eqOn"] as? Bool ?? false }
        var hidden: [String] { raw["hidden"] as? [String] ?? [] }
        var dlDone: Int { (raw["dlDone"] as? NSNumber)?.intValue ?? 0 }
        var dlActive: Int { (raw["dlActive"] as? NSNumber)?.intValue ?? 0 }
        var offline: Bool { raw["offline"] as? Bool ?? false }
        var upcoming: [String] { qi >= 0 && qi + 1 < q.count ? Array(q[(qi + 1)...]) : [] }
        var playing: Bool { !id.isEmpty && !paused }
        func playlist(named n: String) -> [String: Any]? { playlists.first { $0["name"] as? String == n } }
    }

    var state: State {
        let v = probe.value as? String ?? "{}"
        let obj = (try? JSONSerialization.jsonObject(with: Data(v.utf8))) as? [String: Any] ?? [:]
        return State(raw: obj)
    }

    /// Polls the probe until `cond` holds. Returns the matching state (or fails with the last one).
    @discardableResult
    func waitState(_ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
                   _ cond: (State) -> Bool) -> State {
        let deadline = Date().addingTimeInterval(timeout)
        var s = state
        while Date() < deadline {
            s = state
            if cond(s) { return s }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTFail("timed out (\(Int(timeout)) s) waiting for: \(what). Last state: id=\(s.id) title=\(s.title) pos=\(s.pos) paused=\(s.paused) qi=\(s.qi) q=\(s.q.count) src=\(s.src)", file: file, line: line)
        return s
    }

    /// Audio is actually running: playing and the clock advances.
    @discardableResult
    func waitPlaying(_ what: String = "playback", timeout: TimeInterval = 75, file: StaticString = #filePath, line: UInt = #line) -> State {
        let s = waitState("\(what) to start", timeout: timeout, file: file, line: line) { $0.playing && $0.pos > 0.3 }
        let p0 = s.pos
        return waitState("\(what): position to advance from \(p0)", timeout: 12, file: file, line: line) { $0.pos > p0 + 1.5 && !$0.paused }
    }

    // MARK: UI helpers

    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    func button(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }
    /// A button whose label starts with `label` (sheet rows read "Title, subtitle").
    func buttonStarting(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }
    func text(_ label: String) -> XCUIElement { app.staticTexts[label].firstMatch }
    func anyLabeled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    func anyContaining(_ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", s)).firstMatch
    }

    func tap(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(what) should appear", file: file, line: line)
        waitHittable(e, timeout: 5)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !e.isEnabled { pause(0.3) }
        e.tap()
    }

    func waitHittable(_ e: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !e.isHittable { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    }

    func waitGone(_ e: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if !e.exists { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return !e.exists
    }

    func toast(containing s: String, timeout: TimeInterval = 6) -> Bool {
        let t = el("toast")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if t.exists, t.label.localizedCaseInsensitiveContains(s) || t.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", s)).count > 0 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// Search tab → focused field → type → results.
    func search(_ query: String, chip: String? = nil) {
        tap(el("tab-search"), "Search tab")
        if !el("search-input").exists { tap(el("search-field"), "search field") }
        let field = el("search-input")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let old = field.value as? String, !old.isEmpty, old != "What do you want to listen to?" {
            if button("Clear").exists { button("Clear").tap() }
        }
        field.typeText(query)
        // A failed search shows "Try again" (YouTube's bot wall answers 403 in bursts): tap it like a
        // user would, a few times, before calling the flow failed.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && !el("result-row").exists {
            if el("search-retry").exists { pause(8); if el("search-retry").exists { el("search-retry").tap() } }
            pause(0.5)
        }
        XCTAssertTrue(el("result-row").waitForExistence(timeout: 1), "search results for \(query)")
        if let chip {
            // The chip row scrolls sideways: bring the chip into view like a user would.
            let c = button(chip)
            XCTAssertTrue(c.waitForExistence(timeout: 15), "\(chip) chip")
            for _ in 0..<4 where c.frame.maxX > app.frame.width - 8 || c.frame.minX < 0 {
                button("Songs").swipeLeft(); pause(0.4)
            }
            tap(c, "\(chip) chip"); pause(1)
        }
    }

    func resultRow(_ i: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "result-row").element(boundBy: i)
    }
    func trackRow(_ i: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "track-row").element(boundBy: i)
    }

    func openNowPlaying() {
        if el("np-close").exists && el("np-close").isHittable { return }
        dismissKeyboard()
        tap(el("mini-player-text"), "mini player")
        XCTAssertTrue(el("np-close").waitForExistence(timeout: 6))
        waitHittable(el("np-close"), timeout: 3)
    }

    /// The keyboard covers the mini player: put it away like a user (Search key).
    func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let key = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'search' OR label ==[c] 'return' OR label ==[c] 'done'")).firstMatch
        if key.exists { key.tap() } else { app.swipeDown() }
        pause(0.5)
    }

    func closeNowPlaying() {
        let close = el("np-close")
        guard close.exists else { return }
        waitHittable(close, timeout: 4)
        if close.isHittable { close.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        pause(1)
    }

    /// Long-press a row and choose a sheet action.
    func sheetAction(on row: XCUIElement, _ action: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(row.waitForExistence(timeout: 15), "row for \(action)", file: file, line: line)
        row.press(forDuration: 0.8)
        tapSheetRow(action, file: file, line: line)
    }

    /// A row of the open bottom sheet (never a same-named control under it, like the mini player's like).
    func tapSheetRow(_ action: String, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = el("action-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 8), "action sheet for \(action)", file: file, line: line)
        let b = sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", action)).firstMatch
        tap(b, "sheet action \(action)", file: file, line: line)
    }

    /// The core's debug hooks (Playback/DebugAudio.swift), posted as Darwin notifications inside the
    /// simulator: the same path `xcrun simctl spawn … notifyutil -p` takes.
    func debug(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName("app.encore.debug.\(name)" as CFString), nil, nil, true)
    }

    /// Replace a text field's contents (select-all menus are unreliable; delete what is there).
    func replaceText(_ field: XCUIElement, _ text: String) {
        field.tap()
        // The caret goes where the tap lands: put it after the last character first.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2))
        field.typeText(text)
    }

    func pause(_ secs: Double) { RunLoop.current.run(until: Date().addingTimeInterval(secs)) }
}
