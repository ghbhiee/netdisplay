import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

/// Debug demos for the "add a screen" core. These isolate the virtual display
/// from the streaming pipeline so its private-API behavior can be observed.
enum Demos {

    /// `vd-demo`: create a virtual display and print its state once a second so
    /// we can watch whether macOS reverts the mode / arrangement / mirror state
    /// (i.e. whether the enforcement loop is holding).
    /// Create the display and store it ONLY in `demoHold`. No long-lived local
    /// strong ref (a local would outlive `dispatchMain()` and block release).
    private static func holdVirtualDisplay(pixelWidth: Int, pixelHeight: Int, scale: Int, seed: String?) -> CGDirectDisplayID? {
        guard let vd = VirtualDisplay(name: "NetDisplay", pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                      scale: scale, deviceSeed: seed) else { return nil }
        demoHold.append(vd)
        return vd.displayID
    }

    static func vdDemo(pixelWidth: Int, pixelHeight: Int, scale: Int, seconds: Int, seed: String?) -> Never {
        Log.info("vd-demo: creating \(pixelWidth)x\(pixelHeight) scale=\(scale), observing \(seconds)s")
        guard let id = holdVirtualDisplay(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, seed: seed) else {
            Log.error("vd-demo: creation failed"); exit(1)
        }
        var ticks = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            ticks += 1
            let b = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let modeStr = mode.map { "\($0.width)x\($0.height) (px \($0.pixelWidth)x\($0.pixelHeight)) @\(Int($0.refreshRate))" } ?? "nil"
            let mirrored = CGDisplayIsInMirrorSet(id) != 0
            let active = CGDisplayIsActive(id) != 0
            let online = CGDisplayIsOnline(id) != 0
            let main = CGMainDisplayID() == id
            print(String(format: "[t=%2ds] id=%u bounds=(%.0f,%.0f %.0fx%.0f) mode=%@ mirrored=%@ active=%@ online=%@ isMain=%@",
                         ticks, id, b.origin.x, b.origin.y, b.size.width, b.size.height,
                         modeStr, mirrored ? "Y":"N", active ? "Y":"N", online ? "Y":"N", main ? "Y":"N"))
            if ticks >= seconds {
                timer.cancel()
                finish("vd-demo: done.")
            }
        }
        timer.resume()
        demoHold.append(timer)
        dispatchMain()
    }

    /// `capture-demo`: create a virtual display, capture a few frames of it, and
    /// write one to a PNG so we can *see* what's on the added screen (wallpaper +
    /// menu bar = success; black = a compositing problem). BGRA capture so the
    /// frame converts to PNG directly.
    /// Scoped setup: no long-lived local strong refs (they'd block release).
    private static func setupCapture(pixelWidth: Int, pixelHeight: Int, scale: Int, out: String, seed: String?) -> Bool {
        guard let vd = VirtualDisplay(name: "NetDisplay", pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                      scale: scale, deviceSeed: seed) else { return false }
        let cap = Capture(displayID: vd.displayID, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                          pixelFormat: kCVPixelFormatType_32BGRA)
        var saved = false
        let lock = NSLock()
        cap.onFrame = { pixelBuffer, _ in
            lock.lock(); if saved { lock.unlock(); return }; saved = true; lock.unlock()
            let ok = writePNG(pixelBuffer, to: out)
            DispatchQueue.main.async {
                if ok { finish("capture-demo: saved first frame → \(out)") }
                else { Log.error("capture-demo: PNG write failed"); finishErr(1) }
            }
        }
        demoHold.append(vd); demoHold.append(cap)
        Task {
            do { try await cap.start() }
            catch { Log.error("capture-demo: capture start failed \(error)"); finishErr(1) }
        }
        return true
    }

    static func captureDemo(pixelWidth: Int, pixelHeight: Int, scale: Int, out: String, seed: String?) -> Never {
        Log.info("capture-demo: creating \(pixelWidth)x\(pixelHeight) scale=\(scale), will save first frame to \(out)")
        guard setupCapture(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, out: out, seed: seed) else {
            Log.error("capture-demo: creation failed"); exit(1)
        }
        // Timeout: an empty virtual display may never deliver a frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            Log.error("capture-demo: no frame in 8s — the added screen is idle/empty (SCK sends nothing until content changes). Put a window on it and retry.")
            finishErr(2)
        }
        dispatchMain()
    }

    private static func writePNG(_ pixelBuffer: CVPixelBuffer, to path: String) -> Bool {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return false }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }
}

/// Sole owner of demo objects across the run loop, so finish() can release the
/// virtual display (dropping the last strong ref → dealloc → the system removes
/// the display) instead of leaking a zombie the way an abrupt exit() would.
private var demoHold: [Any] = []

private func finish(_ msg: String) {
    Log.info(msg)
    // Paired-removal reap (Chromium workaround) actually removes the display.
    // Demos hold a single VirtualDisplay; make our binding its last strong ref.
    var vd: VirtualDisplay? = demoHold.compactMap { $0 as? VirtualDisplay }.first
    demoHold.removeAll() // drop every other strong ref (timer, capture, array)
    if let display = vd {
        vd = nil // `display` is now the sole owner
        VirtualDisplay.reap(display)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
}

private func finishErr(_ code: Int32) {
    demoHold.removeAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(code) }
}
