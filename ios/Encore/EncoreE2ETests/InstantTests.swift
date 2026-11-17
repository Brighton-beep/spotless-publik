import XCTest

/// stream: instant. Tap → mini player and tap → audible on the real core, from the app's own clock
/// (`PlayerStore.tapped` / `timeTap`, read off the e2e probe). Prints one INSTANT line per tap.
final class InstantTests: E2ECase {
    func test90_TapTimings() {
        launch(reset: true)
        search("Daft Punk", chip: "Songs")
        dismissKeyboard()
        var ui: [Int] = [], audio: [Int] = []
        var prev = ""
        for i in 0..<6 {
            // The song rows themselves (their buttons inherit the identifier, with other labels).
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'result-row' AND label CONTAINS 'Song'")).element(boundBy: i)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.tap()
            let s = waitState("tap \(i) plays", timeout: 75) { ($0.raw["tapAudioMs"] as? Int ?? -1) >= 0 && $0.id != prev }
            let u = s.raw["tapUiMs"] as? Int ?? -1, a = s.raw["tapAudioMs"] as? Int ?? -1
            ui.append(u); audio.append(a); prev = s.id
            print("INSTANT tap=\(i) ui=\(u) audio=\(a) id=\(s.id)")
            pause(2)
        }
        let med = { (x: [Int]) in x.sorted()[x.count / 2] }
        print("INSTANT median ui=\(med(ui)) audio=\(med(audio)) n=\(ui.count)")
    }

    private func songRow(_ i: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'result-row' AND label CONTAINS 'Song'")).element(boundBy: i)
    }
    private func hangs(_ s: State) -> (Int, Int) {
        ((s.raw["hangs"] as? Int) ?? -1, (s.raw["worstHangMs"] as? Int) ?? -1)
    }
    /// Taps right after a play (and right after coming back to the foreground) must land: the
    /// second tap, made while the first song is still starting, is the one that plays. Between the
    /// taps nothing queries the app (each XCUITest element query snapshots the whole accessibility
    /// tree on the app's main thread, which is itself a 100-300 ms stall); taps go to coordinates
    /// found up front. Prints the main-thread stalls over 50 ms (HangWatch) for each phase.
    func test91_TapsLandWhileLoading() {
        launch(reset: true)
        search("Daft Punk", chip: "Songs")
        dismissKeyboard()
        XCTAssertTrue(songRow(4).waitForExistence(timeout: 15))
        pause(3)
        let rows = (0..<5).map { songRow($0) }
        let points = rows.map { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: $0.frame.midX, dy: $0.frame.midY)) }
        let s0 = state
        let (h0, _) = hangs(s0)
        print("INSTANT hangs launch+search=\(h0)")
        // Tap one song, at once scroll a little, then tap another: the second must win.
        points[1].tap()
        let list = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        list.press(forDuration: 0.01, thenDragTo: list.withOffset(CGVector(dx: 0, dy: -60)))
        list.press(forDuration: 0.01, thenDragTo: list.withOffset(CGVector(dx: 0, dy: 60)))
        points[2].tap()
        pause(6)
        let s = state
        let (h1, w1) = hangs(s)
        print("INSTANT second-tap ui=\(s.raw["tapUiMs"] ?? -1) audio=\(s.raw["tapAudioMs"] ?? -1) hangs+=\(h1 - h0) worst=\(w1)ms taps=\((s.raw["taps"] as? Int ?? 0) - (s0.raw["taps"] as? Int ?? 0)) title=\(s.title)")
        XCTAssertEqual((s.raw["taps"] as? Int ?? 0) - (s0.raw["taps"] as? Int ?? 0), 2, "both taps reached the app")
        XCTAssertEqual(s.id, s.raw["tapId"] as? String, "the second tap is the one that plays")
        // Background, back, and tap at once.
        XCUIDevice.shared.press(.home)
        pause(5)
        let sb = state
        let (hb, _) = hangs(sb)
        app.activate()
        points[4].tap()
        pause(6)
        let f = state
        let (h2, w2) = hangs(f)
        print("INSTANT foreground-tap ui=\(f.raw["tapUiMs"] ?? -1) audio=\(f.raw["tapAudioMs"] ?? -1) hangs+=\(h2 - hb) worst=\(w2)ms taps=\((f.raw["taps"] as? Int ?? 0) - (s.raw["taps"] as? Int ?? 0)) title=\(f.title)")
        XCTAssertEqual((f.raw["taps"] as? Int ?? 0) - (s.raw["taps"] as? Int ?? 0), 1, "the tap right after coming back reached the app")
        XCTAssertEqual(f.id, f.raw["tapId"] as? String, "and plays")
    }
}
