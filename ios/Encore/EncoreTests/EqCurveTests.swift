// EQ math parity with the desktop `ui/src/lib/eq-curve.ts` (reference values computed by running
// that file with node).
import XCTest
@testable import Encore

final class EqCurveTests: XCTestCase {
    func testResponseMatchesDesktop() {
        let rock = [5.5, 3.2, -0.1, -1.8, 2.5, 7.0]
        XCTAssertEqual(EQ.responseDb(rock, freq: 60), 3.341028255582845, accuracy: 1e-9)
        XCTAssertEqual(EQ.responseDb(rock, freq: 1000), -1.2404339258862822, accuracy: 1e-9)
        XCTAssertEqual(EQ.responseDb(rock, freq: 15000), 3.5253194994573342, accuracy: 1e-9)
        XCTAssertEqual(EQ.responseDb([0, 0, 6, 0, 0, 0], freq: 400), 6, accuracy: 1e-9)
    }

    func testAutoPreampMatchesDesktop() {
        XCTAssertEqual(EQ.autoPreamp([5.5, 3.2, -0.1, -1.8, 2.5, 7.0]), -6.79, accuracy: 1e-9)
        XCTAssertEqual(EQ.autoPreamp([-6, -3.6, -1.2, 0.2, 0, 0]), 0)
    }

    func testPresetRoundTripAndClamp() {
        for (name, gains) in EQ.presets { XCTAssertEqual(EQ.presetName(gains), name) }
        XCTAssertNil(EQ.presetName([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(EQ.clamp(13), 12)
        XCTAssertEqual(EQ.clamp(-3.14), -3.1)
        XCTAssertEqual(EQ.freqLabel(2400), "2.4KHz")
        XCTAssertEqual(EQ.freqLabel(1000), "1KHz")
        XCTAssertEqual(EQ.freqLabel(60), "60Hz")
    }
}
