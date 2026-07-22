import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Owns the capture → encoder chain. The source is either a virtual display
/// (extend the desktop) or a single app window (project one window). Emits
/// encoded Annex-B access units through `onEncoded`.
final class StreamPipeline {
    private(set) var pixelWidth: Int
    private(set) var pixelHeight: Int
    let fps: Int

    private var virtualDisplay: VirtualDisplay?  // nil in window-projection mode
    private var capture: Capture?
    private var encoder: Encoder?

    // Retained for encoder re-creation on window resize.
    private let encBitrate: Int
    private let encQuality: Bool

    private let pendingLock = NSLock()
    private var pendingEncodes = 0

    private var basePtsUs: UInt64?
    private var stopped = false
    private var restarting = false

    // Window resize-follow.
    private var resizeTimer: DispatchSourceTimer?
    private var reconfiguring = false
    /// Called after the stream size changes (window resize) so the Session can
    /// send VIDEO_CONFIG. (newWidth, newHeight)
    var onReconfigure: ((Int, Int) -> Void)?

    private let statsEnabled = ProcessInfo.processInfo.environment["NETDISPLAY_STATS"] == "1"
    private var capturedCount = 0
    private var encodedCount = 0
    private var statsTimer: DispatchSourceTimer?

    /// Sink for encoded frames. ptsUs is normalized to start near 0.
    var onEncoded: ((_ ptsUs: UInt64, _ isKeyframe: Bool, _ annexB: Data) -> Void)?

    // Designated init: wires pre-built components.
    private init(pixelWidth: Int, pixelHeight: Int, fps: Int, bitrateBps: Int, prioritizeQuality: Bool,
                 encoder: Encoder, capture: Capture, virtualDisplay: VirtualDisplay?) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.encBitrate = bitrateBps
        self.encQuality = prioritizeQuality
        self.encoder = encoder
        self.capture = capture
        self.virtualDisplay = virtualDisplay
        wire(encoder: encoder, capture: capture)
    }

    /// Display mode: create a virtual display and capture it.
    convenience init?(name: String, pixelWidth: Int, pixelHeight: Int, scale: Int, fps: Int,
                      bitrateBps: Int, deviceSeed: String? = nil, prioritizeQuality: Bool = false) {
        guard let vd = VirtualDisplay(name: name, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                      scale: scale, refreshRate: Double(fps), deviceSeed: deviceSeed) else {
            Log.error("failed to create virtual display"); return nil
        }
        guard let enc = Encoder(width: pixelWidth, height: pixelHeight, bitrateBps: bitrateBps,
                                fps: fps, prioritizeQuality: prioritizeQuality) else {
            Log.error("failed to create encoder"); return nil
        }
        let cap = Capture(displayID: vd.displayID, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        self.init(pixelWidth: pixelWidth, pixelHeight: pixelHeight, fps: fps,
                  bitrateBps: bitrateBps, prioritizeQuality: prioritizeQuality,
                  encoder: enc, capture: cap, virtualDisplay: vd)
    }

    /// Window-projection mode: capture a specific already-resolved window.
    static func window(scWindow: SCWindow, pixelWidth: Int, pixelHeight: Int,
                       fps: Int, bitrateBps: Int, prioritizeQuality: Bool = false) -> StreamPipeline? {
        guard let enc = Encoder(width: pixelWidth, height: pixelHeight, bitrateBps: bitrateBps,
                                fps: fps, prioritizeQuality: prioritizeQuality) else {
            Log.error("failed to create encoder"); return nil
        }
        let cap = Capture(window: scWindow, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        return StreamPipeline(pixelWidth: pixelWidth, pixelHeight: pixelHeight, fps: fps,
                              bitrateBps: bitrateBps, prioritizeQuality: prioritizeQuality,
                              encoder: enc, capture: cap, virtualDisplay: nil)
    }

    /// Window-projection mode: capture a single app window (no virtual display).
    static func window(appName: String, fps: Int, bitrateBps: Int,
                       prioritizeQuality: Bool = false) async -> StreamPipeline? {
        do {
            let r = try await WindowPicker.find(appName: appName)
            guard let enc = Encoder(width: r.pixelWidth, height: r.pixelHeight, bitrateBps: bitrateBps,
                                    fps: fps, prioritizeQuality: prioritizeQuality) else {
                Log.error("failed to create encoder"); return nil
            }
            let cap = Capture(window: r.window, pixelWidth: r.pixelWidth, pixelHeight: r.pixelHeight)
            Log.info("window projection: '\(appName)' → \(r.pixelWidth)x\(r.pixelHeight)px")
            return StreamPipeline(pixelWidth: r.pixelWidth, pixelHeight: r.pixelHeight, fps: fps,
                                  bitrateBps: bitrateBps, prioritizeQuality: prioritizeQuality,
                                  encoder: enc, capture: cap, virtualDisplay: nil)
        } catch {
            Log.error("window projection failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func wire(encoder enc: Encoder, capture cap: Capture) {
        enc.onEncoded = { [weak self] ptsUs, key, data in
            guard let self else { return }
            self.pendingLock.lock(); self.pendingEncodes = max(0, self.pendingEncodes - 1); self.encodedCount += 1; self.pendingLock.unlock()
            let normalized: UInt64
            if let base = self.basePtsUs {
                normalized = ptsUs >= base ? ptsUs - base : 0
            } else {
                self.basePtsUs = ptsUs
                normalized = 0
            }
            self.onEncoded?(normalized, key, data)
        }
        cap.onFrame = { [weak self] pixelBuffer, pts in
            guard let self, let encoder = self.encoder else { return }
            // Skip frames whose size doesn't match the current encoder (resize transition).
            if CVPixelBufferGetWidth(pixelBuffer) != self.pixelWidth ||
               CVPixelBufferGetHeight(pixelBuffer) != self.pixelHeight { return }
            self.pendingLock.lock()
            self.capturedCount += 1
            if self.pendingEncodes >= 2 { self.pendingLock.unlock(); return }
            self.pendingEncodes += 1
            self.pendingLock.unlock()
            encoder.encode(pixelBuffer: pixelBuffer, pts: pts)
        }
        cap.onStoppedWithError = { [weak self] in self?.restartCapture() }
    }

    /// SCK sometimes drops the source transiently. Restart capture with backoff.
    private func restartCapture() {
        guard !stopped, !restarting, let capture else { return }
        restarting = true
        Task {
            for attempt in 1...10 {
                if stopped { return }
                try? await Task.sleep(nanoseconds: UInt64(min(5, attempt)) * 500_000_000)
                do {
                    try await capture.start()
                    Log.info("capture restarted after transient stop (attempt \(attempt))")
                    self.restarting = false
                    return
                } catch {
                    Log.info("capture restart attempt \(attempt) failed: \(error.localizedDescription)")
                }
            }
            Log.error("capture could not be restarted after 10 attempts")
            self.restarting = false
        }
    }

    private func startStats() {
        guard statsEnabled else { return }
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let c = self.capturedCount, e = self.encodedCount
            self.capturedCount = 0; self.encodedCount = 0
            self.pendingLock.unlock()
            Log.info("stats: captured=\(c)/s encoded=\(e)/s")
        }
        statsTimer = t
        t.resume()
    }

    var isValid: Bool { encoder != nil && capture != nil }

    func start() async throws {
        guard let capture else {
            throw NSError(domain: "netdisplay.pipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "pipeline not initialized"])
        }
        try await capture.start()
        startStats()
        if capture.windowID != nil { startResizeFollow() }
    }

    /// Poll the projected window's size; when it settles at a new size, swap the
    /// encoder + reconfigure the stream + notify (Session sends VIDEO_CONFIG).
    private func startResizeFollow() {
        guard let winID = capture?.windowID else { return }
        var stableCount = 0
        var pendingSize: (Int, Int)?
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 0.5, repeating: 0.4)
        t.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.reconfiguring else { return }
            Task {
                guard let (w, h) = await WindowPicker.currentSize(windowID: winID) else {
                    if self.statsEnabled { Log.info("resize-poll: window \(winID) size not found") }
                    return
                }
                if w == self.pixelWidth && h == self.pixelHeight { pendingSize = nil; stableCount = 0; return }
                // Debounce: require the new size to hold for ~2 polls before reconfiguring.
                if let p = pendingSize, p == (w, h) { stableCount += 1 } else { pendingSize = (w, h); stableCount = 1 }
                if stableCount >= 2 {
                    pendingSize = nil; stableCount = 0
                    await self.reconfigure(width: w, height: h)
                }
            }
        }
        resizeTimer = t
        t.resume()
    }

    private func reconfigure(width: Int, height: Int) async {
        guard !stopped, !reconfiguring, let capture else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        guard let newEnc = Encoder(width: width, height: height, bitrateBps: encBitrate,
                                   fps: fps, prioritizeQuality: encQuality) else {
            Log.error("reconfigure: encoder re-create failed"); return
        }
        // Swap encoder + capture size together. The onFrame size-guard skips any
        // in-flight old-size frames until the capture reconfigure lands.
        wire(encoder: newEnc, capture: capture)
        encoder = newEnc           // old encoder deallocs → VT session invalidated
        pixelWidth = width; pixelHeight = height
        await capture.reconfigure(pixelWidth: width, pixelHeight: height)
        newEnc.requestKeyframe()   // receiver resets decoder on VIDEO_CONFIG, needs a fresh IDR
        Log.info("pipeline reconfigured → \(width)x\(height); notifying VIDEO_CONFIG")
        onReconfigure?(width, height)
    }

    func requestKeyframe() { encoder?.requestKeyframe() }

    func stop() {
        stopped = true
        statsTimer?.cancel(); statsTimer = nil
        resizeTimer?.cancel(); resizeTimer = nil
        Task { [capture] in await capture?.stop() }
        capture = nil
        encoder = nil
        if let vd = virtualDisplay {
            virtualDisplay = nil // hand the sole reference to reap
            VirtualDisplay.reap(vd)
        }
    }
}
