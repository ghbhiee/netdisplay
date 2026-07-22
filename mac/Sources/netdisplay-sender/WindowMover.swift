import Foundation
import ApplicationServices
import AppKit

/// Moves another app's window between displays via the Accessibility API.
/// Requires the Accessibility (辅助功能) permission — the same one used later
/// for keyboard/mouse input-back.
enum WindowMover {
    /// True if this process is trusted for Accessibility. Pass prompt:true to
    /// surface the system prompt (opens System Settings → Privacy → Accessibility).
    @discardableResult
    static func hasPermission(prompt: Bool = false) -> Bool {
        // Key string is stable ("AXTrustedCheckOptionPrompt"); avoids CFString bridging quirks.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Move the app's front window so its top-left sits at `topLeft` (global CG
    /// coords, top-left origin). Returns the previous top-left for restoring.
    @discardableResult
    static func moveFrontWindow(pid: pid_t, to topLeft: CGPoint) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        guard let win = frontWindow(of: app) else {
            Log.error("window mover: no AX window for pid \(pid) (Accessibility 权限?)")
            return nil
        }
        let prev = position(of: win)
        setPosition(win, topLeft)
        Log.info("window mover: moved pid \(pid) window to (\(Int(topLeft.x)),\(Int(topLeft.y)))")
        return prev
    }

    private static func frontWindow(of app: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &v) == .success, let v {
            return (v as! AXUIElement)
        }
        var wv: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wv) == .success,
           let arr = wv as? [AXUIElement], let first = arr.first {
            return first
        }
        return nil
    }

    private static func position(of win: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &v) == .success, let v else { return nil }
        var p = CGPoint.zero
        AXValueGetValue((v as! AXValue), .cgPoint, &p)
        return p
    }

    private static func setPosition(_ win: AXUIElement, _ p: CGPoint) {
        var pp = p
        if let ax = AXValueCreate(.cgPoint, &pp) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, ax)
        }
    }
}
