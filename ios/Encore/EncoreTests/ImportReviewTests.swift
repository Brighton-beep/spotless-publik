// The import's review step (stream ios-import-review, simplified by stream onboard): the summary,
// the check list, the candidate sheet, Looks right / Leave out through `import_pick`, Looks good
// (create), and the Done line of a re-imported playlist.
import XCTest
@testable import Encore

final class ImportReviewTests: SnapshotCase {
    override func setUp() async throws {
        try await super.setUp()
        ImportFlow.shared.reset()
    }

    /// The export read and matched on the mock core, sitting in review.
    private func review(_ app: AppModel) async {
        let f = ImportFlow.shared
        f.live = false
        await f.readFile(URL(fileURLWithPath: "/tmp/my_spotify_data.zip"), app)
        await f.start(app)
        for _ in 0..<40 where (try? await app.core.importStatus())?.phase != "review" {
            try? await Task.sleep(for: .milliseconds(150))
        }
        f.snapshot = try? await app.core.importStatus()
        await f.openReview(app)
    }

    /// The summary leads: "N songs matched", Looks good, and one quiet link. No rows are loaded
    /// until the link is used (stream onboard).
    func testReviewSummary() async {
        await snap("encore://import", setup: { app in await self.review(app) })
        let f = ImportFlow.shared
        XCTAssertEqual(f.step, .review)
        XCTAssertTrue(f.rows.isEmpty, "nothing loaded before Check")
        let s = try? XCTUnwrap(f.snapshot)
        XCTAssertEqual(f.readyCount, (s?.matched ?? 0) + (s?.check ?? 0))
        XCTAssertEqual(f.checkTitle, "Check \(s?.check ?? 0) uncertain ones")
        XCTAssertEqual(f.addsLine, "Adds 5 playlists and your Liked Songs to Your Library.")
    }

    func testSummaryLinkWithoutUncertainOnes() async {
        await review(app)
        let f = ImportFlow.shared
        f.snapshot?.check = 0
        XCTAssertEqual(f.checkTitle, "See \(f.snapshot?.missing ?? 0) not found")
        f.snapshot?.missing = 0
        XCTAssertEqual(f.checkTitle, "See all songs")
    }

    /// The check list: uncertain first, then not found; the matched ones only on request.
    func testCheckList() async {
        await snap("encore://import", setup: { app in
            await self.review(app)
            await ImportFlow.shared.openCheck(app)
        })
        let f = ImportFlow.shared
        XCTAssertEqual(f.step, .check)
        XCTAssertNil(f.tiers["matched"])
        XCTAssertFalse(f.tiers["check"]?.isEmpty ?? true)
        XCTAssertFalse(f.tiers["missing"]?.isEmpty ?? true)
        XCTAssertTrue(f.tiers["check"]!.allSatisfy { $0.tier == "check" && $0.pick != nil && !$0.candidates.isEmpty })
        XCTAssertTrue(f.tiers["missing"]!.allSatisfy { $0.pick == nil })
        XCTAssertEqual(f.rows.first?.tier, "check", "uncertain ones lead")
    }

    func testCheckListShowsMatched() async {
        await review(app)
        let f = ImportFlow.shared
        await f.openCheck(app)
        await f.loadRows(app, tier: "matched")
        XCTAssertTrue(f.tiers["matched"]!.allSatisfy { $0.candidates.isEmpty && $0.pick != nil })
        XCTAssertEqual(f.rows.last?.tier, "matched")
    }

    func testChooseSheet() async {
        await snap("encore://import", setup: { app in
            await self.review(app)
            await ImportFlow.shared.openCheck(app)
            ImportFlow.shared.choosing = ImportFlow.shared.rows.first
        }, wait: 1.5)
    }

    func testSettledRows() async {
        await snap("encore://import", setup: { app in
            await self.review(app)
            let f = ImportFlow.shared
            await f.openCheck(app)
            let rows = f.rows
            await f.choose(rows[0], rows[0].candidates[1], app) // another candidate
            await f.choose(rows[1], nil, app)                    // left out
            await f.choose(rows[2], rows[2].pick, app)           // looks right
        })
        let f = ImportFlow.shared
        XCTAssertEqual(f.settled[f.rows[0].key], true)
        XCTAssertEqual(f.rows[0].pick?.videoId, f.rows[0].candidates[1].videoId)
        XCTAssertEqual(f.settled[f.rows[1].key], false)
        XCTAssertEqual(f.settled[f.rows[2].key], true)
        XCTAssertNil(f.choosing)
    }

    func testPickMovesCounts() async throws {
        await review(app)
        let f = ImportFlow.shared
        await f.openCheck(app)
        let before = try XCTUnwrap(f.snapshot)
        await f.choose(f.rows[0], nil, app)
        XCTAssertEqual(f.snapshot?.check, before.check - 1)
        XCTAssertEqual(f.snapshot?.missing, before.missing + 1)
        await f.choose(f.rows[1], f.rows[1].pick, app)
        XCTAssertEqual(f.snapshot?.matched, before.matched + 1)
        // The core's rows follow: the left-out one is under Not found now.
        let missing = try await app.core.importRows(tier: "missing")
        XCTAssertTrue(missing.contains { $0.key == f.rows[0].key })
    }

    func testCreateGoesToDone() async throws {
        await review(app)
        let f = ImportFlow.shared
        await f.create(app)
        XCTAssertTrue(f.creating)
        XCTAssertEqual(f.step, .progress)
        let s = try await app.core.importStatus()
        XCTAssertEqual(s?.phase, "done")
        XCTAssertEqual(s?.results.count, 6)
    }

    func testDoneWithReimportedPlaylist() async {
        await snap("encore://import", setup: { app in
            await self.review(app)
            let f = ImportFlow.shared
            guard var s = f.snapshot else { return XCTFail("no import snapshot") }
            s.phase = "done"
            s.results = [
                ImportResult(kind: "liked", name: "Liked Songs", id: "VLLM", local: true, added: 0, missing: 0, removed: 0),
                ImportResult(kind: "playlist", name: s.lists[1].name, id: "LOCALPLAYLIST:1", local: true, added: 1, missing: 0, removed: 0, updated: true),
                ImportResult(kind: "playlist", name: s.lists[2].name, id: "LOCALPLAYLIST:2", local: true, added: 31, missing: 2, removed: 0),
            ]
            f.snapshot = s
            f.step = .done
        })
    }

    func testResultLines() {
        let r = { (added: Int, missing: Int, updated: Bool?) in
            resultLine(ImportResult(kind: "playlist", name: "x", id: "LOCALPLAYLIST:1", local: true, added: added, missing: missing, removed: 0, updated: updated))
        }
        XCTAssertEqual(r(8, 0, nil), "8 songs")
        XCTAssertEqual(r(1, 0, true), "Already imported • 1 new song")
        XCTAssertEqual(r(0, 2, true), "Already imported • 0 new songs • 2 not found")
        XCTAssertEqual(r(1, 1, false), "1 song • 1 not found")
        XCTAssertEqual(resultLine(ImportResult(kind: "liked", name: "Liked Songs", id: "VLLM", local: true, added: 0, missing: 0, removed: 0)),
                       "Already in your Liked Songs")
    }

    func testYouTubeLinks() {
        XCTAssertEqual(youTubeVideoId("https://music.youtube.com/watch?v=abc123&list=x"), "abc123")
        XCTAssertEqual(youTubeVideoId("https://youtu.be/xyz789?si=1"), "xyz789")
        XCTAssertEqual(youTubeVideoId("https://www.youtube.com/shorts/sh0rt"), "sh0rt")
        XCTAssertNil(youTubeVideoId("Get Lucky Daft Punk"))
        XCTAssertNil(youTubeVideoId("https://open.spotify.com/track/1"))
    }

    func testDecodesCoreRows() throws {
        let json = """
        [{"key":"4uLU6hMCjMI75M1A2tKUQC","title":"Get Lucky","artists":"Daft Punk, Pharrell Williams","album":"Random Access Memories",
          "durationMs":369000,"tier":"check","pick":{"video_id":"5NV6Rdv1a3I","title":"Get Lucky","artists":"Daft Punk"},
          "candidates":[{"video_id":"5NV6Rdv1a3I","title":"Get Lucky","artists":"Daft Punk"}]}]
        """
        let rows = try JSONDecoder().decode([ImportRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.first?.pick?.videoId, "5NV6Rdv1a3I")
        XCTAssertEqual(mmss(rows.first?.durationMs), "6:09")
        let done = try JSONDecoder().decode(ImportResult.self, from: Data(#"{"kind":"playlist","name":"x","id":"LOCALPLAYLIST:3","local":true,"added":1,"missing":0,"removed":0,"updated":true}"#.utf8))
        XCTAssertEqual(done.updated, true)
    }
}
