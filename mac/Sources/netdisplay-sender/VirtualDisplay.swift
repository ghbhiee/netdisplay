import Foundation
import CoreGraphics
import Security
import CVirtualDisplay

/// Wraps the private CGVirtualDisplay API to make macOS believe a real monitor
/// is attached, sized so ScreenCaptureKit captures a 1:1 `pixelWidth×pixelHeight`
/// image for the Receiver.
///
/// macOS asynchronously reverts a freshly created virtual display — drops it to
/// 1x, restores a stale saved mode, re-mirrors it, moves it. So mode/mirror/
/// origin are **enforced** on a loop for the display's lifetime, closely
/// following peetzweg/opendisplay's VirtualDisplay.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    private let settings: CGVirtualDisplaySettings
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int

    private let pointsWide: Int
    private let pointsHigh: Int

    private var restoreTarget: CGPoint?
    private let restoreUntil: Date
    private var enforceTask: Task<Void, Never>?

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: physical framebuffer size (what we encode).
    ///   - scale: >=2 → HiDPI (@scale) display with point size pixel/scale; 1 → plain 1x.
    ///   - deviceSeed: stable per-device value; a stable serial keeps the display's
    ///     arrangement across runs. Falls back to random serials if creation fails
    ///     (e.g. a leaked zombie display collides on identity).
    init?(name: String, pixelWidth: Int, pixelHeight: Int, scale: Int,
          refreshRate: Double = 60, deviceSeed: String? = nil) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight

        let s = max(1, scale)
        let hidpi = s >= 2
        self.pointsWide = pixelWidth / s
        self.pointsHigh = pixelHeight / s

        // ~110 PPI → millimeters, drives the system's default scaling feel.
        let mmWidth = Double(pixelWidth) / 110.0 * 25.4
        let mmHeight = Double(pixelHeight) / 110.0 * 25.4
        let sizeMM = CGSize(width: mmWidth, height: mmHeight)

        // Park to the right of the main display for the first few seconds.
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        self.restoreTarget = CGPoint(x: mainBounds.maxX, y: mainBounds.minY)
        self.restoreUntil = Date().addingTimeInterval(6)

        // Try a stable serial first (arrangement memory), then random fallbacks
        // (a leaked zombie display sharing vendor/product/serial makes apply fail).
        let serials: [UInt32] = [Self.stableSerial(deviceSeed), Self.randomSerial(), Self.randomSerial(), Self.randomSerial()]
        var made: (CGVirtualDisplay, CGVirtualDisplaySettings)?
        for (i, serial) in serials.enumerated() {
            if let m = Self.build(name: name, pointsWide: pointsWide, pointsHigh: pointsHigh,
                                  pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                  hidpi: hidpi, sizeMM: sizeMM, refreshRate: refreshRate, serial: serial) {
                made = m
                if i > 0 { Log.info("virtual display created on serial attempt \(i + 1)") }
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let (disp, st) = made else {
            Log.error("CGVirtualDisplay creation failed after \(serials.count) attempts")
            return nil
        }

        self.display = disp
        self.settings = st
        self.displayID = disp.displayID
        Log.info("virtual display created: id=\(disp.displayID) \(pixelWidth)x\(pixelHeight)px (\(pointsWide)x\(pointsHigh)pt, hiDPI=\(hidpi))")

        startEnforcement()
    }

    deinit {
        enforceTask?.cancel()
    }

    /// Reliably remove the virtual display. macOS async-removes a display when
    /// its last strong reference drops, BUT the first removal in a process has a
    /// known flaky timeout unless a *second* display is removed at the same time
    /// (per Chromium's ui/display/mac/test/virtual_display_util_mac.mm
    /// `g_need_display_removal_workaround`). So we spin up a throwaway display,
    /// release both, and wait for the online list to confirm they're gone.
    ///
    /// Pass the sole owning reference (`consuming`) — the caller must have
    /// already dropped its own. Blocks up to `timeout`. Returns true if removed.
    @discardableResult
    static func reap(_ wrapper: consuming VirtualDisplay, timeout: TimeInterval = 4.5) -> Bool {
        let realID = wrapper.displayID
        wrapper.enforceTask?.cancel()

        // Throwaway paired removal to dodge the flaky first-removal timeout.
        var temp = makeBareDisplay(serial: randomSerial())
        let tempID = temp?.displayID ?? 0

        _ = consume wrapper // ends the wrapper's life → inner CGVirtualDisplay released
        temp = nil          // release the throwaway too

        let ok = waitForRemoval(Set([realID, tempID].filter { $0 != 0 }), timeout: timeout)
        Log.info("reap: real=\(realID) temp=\(tempID) removed=\(ok)")
        return ok
    }

    /// Minimal unmanaged virtual display used only as the paired throwaway in reap.
    private static func makeBareDisplay(serial: UInt32) -> CGVirtualDisplay? {
        let sizeMM = CGSize(width: 800.0 / 110.0 * 25.4, height: 600.0 / 110.0 * 25.4)
        return build(name: "NetDisplay-reap", pointsWide: 800, pointsHigh: 600,
                     pixelWidth: 800, pixelHeight: 600, hidpi: false,
                     sizeMM: sizeMM, refreshRate: 60, serial: serial)?.0
    }

    private static func waitForRemoval(_ ids: Set<CGDirectDisplayID>, timeout: TimeInterval) -> Bool {
        guard !ids.isEmpty else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var n: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &n)
            var list = [CGDirectDisplayID](repeating: 0, count: Int(n))
            CGGetOnlineDisplayList(n, &list, &n)
            if ids.isDisjoint(with: list) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// One create+apply attempt with a given serial. Returns nil on apply failure.
    private static func build(name: String, pointsWide: Int, pointsHigh: Int,
                              pixelWidth: Int, pixelHeight: Int, hidpi: Bool,
                              sizeMM: CGSize, refreshRate: Double, serial: UInt32)
        -> (CGVirtualDisplay, CGVirtualDisplaySettings)? {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        descriptor.sizeInMillimeters = sizeMM
        descriptor.productID = 0x4F53 // "OS"
        descriptor.vendorID = 0x5043  // "PC"
        descriptor.serialNum = serial
        descriptor.terminationHandler = { _, _ in
            Log.info("virtual display terminated by the system")
        }
        let disp = CGVirtualDisplay(descriptor: descriptor)
        let st = CGVirtualDisplaySettings()
        st.hiDPI = hidpi ? 1 : 0
        st.modes = [CGVirtualDisplayMode(width: UInt(pointsWide), height: UInt(pointsHigh), refreshRate: refreshRate)]
        return disp.apply(st) ? (disp, st) : nil
    }

    // MARK: - Enforcement (persistent, for the display's lifetime)

    private func startEnforcement() {
        enforceTask = Task { @MainActor [weak self] in
            var settled = false
            while !Task.isCancelled {
                if let self {
                    self.ensureNotMirrored()
                    if self.selectMode(recover: settled) { settled = true }
                    self.manageOrigin()
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(settled ? 2_000 : 200) * 1_000_000)
            }
        }
    }

    /// Re-assert our intended display mode (1x or HiDPI). macOS defaults a new
    /// display to 1x and can restore a stale saved mode seconds later, so this
    /// runs as continuous enforcement. `recover` re-applies settings if our mode
    /// vanished entirely (macOS can replace the whole mode list).
    @discardableResult
    private func selectMode(recover: Bool) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let want = modes.first(where: { $0.width == pointsWide && $0.pixelWidth == pixelWidth }) else {
            if recover {
                Log.info("target mode vanished from display \(displayID) — re-applying settings")
                _ = display.apply(settings)
            }
            return false
        }
        if let cur = CGDisplayCopyDisplayMode(displayID),
           cur.width == want.width, cur.pixelWidth == want.pixelWidth {
            return true
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayWithDisplayMode(config, displayID, want, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        Log.info("mode (re)selected: \(want.width)x\(want.height) (px \(want.pixelWidth)x\(want.pixelHeight), result \(err.rawValue))")
        return err == .success
    }

    /// Restore our target origin (right of main) for the first few seconds —
    /// macOS restores its own stale arrangement asynchronously. After that,
    /// stop forcing so the user can drag the display where they like.
    private func manageOrigin() {
        let id = displayID
        let origin = CGDisplayBounds(id).origin
        guard let target = restoreTarget, Date() < restoreUntil else { return }
        guard origin != target else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, id, Int32(target.x), Int32(target.y))
        _ = CGCompleteDisplayConfiguration(config, .permanently)
        // WindowServer snaps to the nearest valid arrangement; adopt the result
        // so we don't fight the snap every tick.
        restoreTarget = CGDisplayBounds(id).origin
    }

    /// An extend-mode virtual display must never sit in a mirror set. Detach the
    /// VD itself and any display mirroring it. `.forSession` scope — permanent
    /// mirror reconfig of the private VD is rejected.
    private func ensureNotMirrored() {
        let id = displayID
        guard CGDisplayIsInMirrorSet(id) != 0 else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &list, &n)
        for other in list where other != id && CGDisplayMirrorsDisplay(other) == id {
            CGConfigureDisplayMirrorOfDisplay(config, other, kCGNullDirectDisplay)
        }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info("virtual display \(id) was mirrored — detached to extend (result \(err.rawValue))")
    }

    // MARK: - Serials

    private static func randomSerial() -> UInt32 {
        var raw: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &raw) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return raw | 1
    }

    /// Stable per-device serial (FNV-1a of the seed), so arrangement persists
    /// across normal runs. Nonzero, avoids the reserved 0x0001.
    private static func stableSerial(_ seed: String?) -> UInt32 {
        guard let seed, !seed.isEmpty else { return 0x4E455430 }
        var h: UInt32 = 2166136261
        for b in seed.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h == 0 || h == 1 ? 0x4E455431 : h
    }
}
