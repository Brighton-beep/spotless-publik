// The TestFlight build 10/11 crash: mpv's video thread ("vo") changed mpv's layer while it sat in the
// window. When that thread exited (the picture closing), its implicit CATransaction committed and
// laid out UIKit views from "vo": Auto Layout's thread assertion. These tests exit real threads.
import XCTest
import UIKit
import Metal
@testable import Encore

/// Counts the layouts that run off the main thread.
private final class Sentinel: UIView {
    let lock = NSLock()
    private var count = 0
    var offMain: Int { lock.lock(); defer { lock.unlock() }; return count }
    override func layoutSubviews() {
        super.layoutSubviews()
        if !Thread.isMainThread { lock.lock(); count += 1; lock.unlock() }
    }
}

private final class PlainMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}

private final class Box { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }

/// Runs `body` on a new thread named "vo" and waits for it to exit, the main thread blocked meanwhile
/// (so nothing commits in between, as when mpv closes its output).
private func runOnVoThread(_ body: @escaping () -> Void) {
    let box = Unmanaged.passRetained(Box(body)).toOpaque()
    var t: pthread_t?
    pthread_create(&t, nil, { arg in
        pthread_setname_np("vo")
        Unmanaged<Box>.fromOpaque(arg).takeRetainedValue().f()
        return nil
    }, box)
    pthread_join(t!, nil)
}

@MainActor
final class VideoThreadTests: XCTestCase {
    private var window: UIWindow?
    override func tearDown() async throws { window?.isHidden = true; window = nil }

    /// A window with a view waiting for layout, and `view` in it.
    private func host(_ view: UIView) async throws -> Sentinel {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let sentinel = Sentinel(frame: w.bounds)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        sentinel.addSubview(view)
        w.addSubview(sentinel)
        w.isHidden = false
        window = w
        try? await Task.sleep(for: .milliseconds(100))
        sentinel.setNeedsLayout()
        return sentinel
    }

    /// The mechanism: a layer change from a thread that then exits lays out the window from that thread.
    func testAThreadExitCommitsItsLayerChangesAndLaysOutOffMain() async throws {
        let v = PlainMetalView()
        let sentinel = try await host(v)
        runOnVoThread { v.layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 160) }
        XCTAssertGreaterThan(sentinel.offMain, 0, "UIKit laid out from the exiting thread (Auto Layout would assert)")
    }

    /// The fix: every call MoltenVK makes on mpv's layer from "vo" (the selectors libMoltenVK.a sends)
    /// leaves the layer alone on that thread. Values it already has are dropped, drawable settings
    /// that differ land on the main thread, and display settings stay the app's.
    func testMoltenVKWritesFromVoNeverTouchTheLayer() async throws {
        let v = MPVLayerView(frame: .zero)
        let layer = v.metal
        let sentinel = try await host(v)
        let size = layer.drawableSize
        let device = layer.device
        let opaque = layer.isOpaque
        runOnVoThread {
            // What MVKSwapchain sets for a swapchain like libplacebo's: the same values as the app's
            // (no-ops), one new pixel format, and its own display choices.
            layer.drawableSize = size
            layer.device = device
            layer.framebufferOnly = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.pixelFormat = .bgra8Unorm
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            layer.contentsGravity = .resize
            layer.isOpaque = !opaque
            layer.wantsExtendedDynamicRangeContent = false
            layer.drawableSize = CGSize(width: 1, height: 1)
            layer.setNeedsDisplay()
            layer.setNeedsDisplay(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        XCTAssertEqual(sentinel.offMain, 0, "nothing laid out from the exiting thread")
        XCTAssertEqual(layer.pixelFormat, .bgr10a2Unorm, "not set from \"vo\"")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm, "a drawable setting MoltenVK needs lands on the main thread")
        XCTAssertEqual(layer.drawableSize, size, "the fixed drawable; MoltenVK's 1x1 is ignored")
        XCTAssertEqual(layer.contentsGravity, .resizeAspect, "letterboxed, always")
        XCTAssertEqual(layer.magnificationFilter, .linear)
        XCTAssertEqual(layer.minificationFilter, .linear)
        XCTAssertEqual(layer.isOpaque, opaque)
    }
}
