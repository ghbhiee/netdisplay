import AppKit

/// Design tokens from docs/design (原型 v2.dc.html) — exact light/dark palettes.
/// Colors resolve dynamically to the current appearance so the whole UI follows
/// the system (or an explicit override) light/dark theme.
enum Theme {
    /// User theme override: nil = follow system.
    static var override: NSAppearance.Name? {
        didSet {
            if let n = override { NSApp.appearance = NSAppearance(named: n) }
            else { NSApp.appearance = nil }
        }
    }

    private static func hex(_ s: String) -> NSColor {
        var h = s; if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// Dynamic color: picks `light` or `dark` per the resolved appearance.
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    static let bg        = dyn(hex("E9EBEE"), hex("141619"))
    static let panel     = dyn(hex("FFFFFF"), hex("1F2226"))
    static let panel2     = dyn(hex("F5F6F8"), hex("282C31"))
    static let text      = dyn(hex("1B1E23"), hex("E9EBEE"))
    static let sub       = dyn(hex("6E7681"), hex("98A0A9"))
    static let line      = dyn(hex("E2E4E8"), hex("34383E"))
    static let accent    = dyn(hex("3B6FE0"), hex("5C88E8"))
    static let accentWeak = dyn(NSColor(srgbRed: 59/255, green: 111/255, blue: 224/255, alpha: 0.10),
                                NSColor(srgbRed: 92/255, green: 136/255, blue: 232/255, alpha: 0.16))
    static let recv      = dyn(hex("0F9D8C"), hex("31BFAD"))
    static let recvWeak  = dyn(NSColor(srgbRed: 15/255, green: 157/255, blue: 140/255, alpha: 0.12),
                               NSColor(srgbRed: 49/255, green: 191/255, blue: 173/255, alpha: 0.16))
    static let ok        = dyn(hex("1D9E55"), hex("3DBE74"))
    static let err       = dyn(hex("D5453C"), hex("E4655C"))
}
