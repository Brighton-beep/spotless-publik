// Snapshots of the shell screens that existed before ios-screens2 (regression guard).
import XCTest
@testable import Encore

final class ShellSnapshotTests: SnapshotCase {
    func testHome() async { await snap("encore://home") }
    func testLibrary() async { await snap("encore://library") }
}
