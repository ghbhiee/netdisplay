import Foundation
import ScreenCaptureKit
import AppKit

/// Finds an on-screen window belonging to a named app and computes its native
/// pixel size (for single-window projection).
enum WindowPicker {
    struct Resolved {
        let window: SCWindow
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: CGFloat
        let pid: pid_t
    }

    /// Match by app display name or bundle id (case-insensitive substring),
    /// preferring the largest on-screen window.
    static func find(appName: String) async throws -> Resolved {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let needle = appName.lowercased()
        let matches = content.windows.filter { w in
            guard let app = w.owningApplication else { return false }
            let name = app.applicationName.lowercased()
            let bundle = app.bundleIdentifier.lowercased()
            let hit = name.contains(needle) || bundle.contains(needle)
            return hit && w.isOnScreen && w.frame.width > 80 && w.frame.height > 80
        }.sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }

        guard let win = matches.first else {
            let avail = Set(content.windows.compactMap { $0.owningApplication?.applicationName })
                .sorted().prefix(20).joined(separator: ", ")
            throw NSError(domain: "netdisplay.window", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "没找到 '\(appName)' 的可见窗口。当前可投的 App：\(avail)"])
        }
        let scale = screenScale(for: win.frame)
        let pw = max(2, Int((win.frame.width * scale).rounded()) & ~1)
        let ph = max(2, Int((win.frame.height * scale).rounded()) & ~1)
        return Resolved(window: win, pixelWidth: pw, pixelHeight: ph, scale: scale,
                        pid: win.owningApplication?.processID ?? 0)
    }

    /// The frontmost user window sitting on a given display (for stage-follow):
    /// pick the on-screen window whose center is within `displayBounds`, lowest
    /// window layer (= frontmost), excluding our own app.
    static func frontmostOnDisplay(_ displayBounds: CGRect) async -> Resolved? {
        // Exclude desktop/wallpaper windows; list is front-to-back.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        for win in content.windows {  // index 0 = frontmost
            guard let app = win.owningApplication, app.processID != mine else { continue }
            if win.windowLayer != 0 { continue }  // normal app windows only (skip panels/menubar)
            let c = CGPoint(x: win.frame.midX, y: win.frame.midY)
            guard win.isOnScreen, win.frame.width > 80, win.frame.height > 80, displayBounds.contains(c) else { continue }
            let scale = screenScale(for: win.frame)
            let pw = max(2, Int((win.frame.width * scale).rounded()) & ~1)
            let ph = max(2, Int((win.frame.height * scale).rounded()) & ~1)
            return Resolved(window: win, pixelWidth: pw, pixelHeight: ph, scale: scale, pid: app.processID)
        }
        return nil
    }

    /// Current native pixel size of a specific window (for resize-follow).
    static func currentSize(windowID: CGWindowID) async -> (width: Int, height: Int)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let w = content.windows.first(where: { $0.windowID == windowID }), w.isOnScreen else { return nil }
        let scale = screenScale(for: w.frame)
        let pw = max(2, Int((w.frame.width * scale).rounded()) & ~1)
        let ph = max(2, Int((w.frame.height * scale).rounded()) & ~1)
        return (pw, ph)
    }

    /// Backing scale of the screen a window sits on (retina = 2). Coordinate
    /// spaces differ (SCWindow is top-left, NSScreen bottom-left), so this is a
    /// best-effort match; falls back to the main screen's scale.
    static func screenScale(for frame: CGRect) -> CGFloat {
        let cx = frame.midX
        for s in NSScreen.screens {
            let f = s.frame
            if cx >= f.minX && cx <= f.maxX { return s.backingScaleFactor }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Distinct app names that currently have an on-screen window (for menus).
    static func projectableApps() async -> [String] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        var names: [String] = []
        for w in content.windows where w.isOnScreen && w.frame.width > 200 && w.frame.height > 150 {
            if let n = w.owningApplication?.applicationName, !names.contains(n) { names.append(n) }
        }
        return names.sorted()
    }
}
