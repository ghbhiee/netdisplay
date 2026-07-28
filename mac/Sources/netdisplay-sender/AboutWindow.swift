import AppKit

/// The app icon, loaded from the bundle (falls back to the system app icon when
/// run un-bundled, e.g. `swift run`).
enum AppAssets {
    static let icon: NSImage? = {
        if let p = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let img = NSImage(contentsOfFile: p) { return img }
        let appIcon = NSApp.applicationIconImage
        return (appIcon?.size.width ?? 0) > 0 ? appIcon : nil
    }()
}

/// 关于 NetDisplay — icon + author + a plain clickable GitHub link (no button,
/// the URL itself isn't shown). Single reused window.
enum AboutWindow {
    private static var win: NSWindow?
    private static var linkTarget: GenCodeTarget?

    static func show() {
        if let w = win { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let W: CGFloat = 320
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 250),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "关于 NetDisplay"
        w.backgroundColor = Theme.panel
        w.isReleasedWhenClosed = false
        let root = FlippedView(); root.wantsLayer = true
        w.contentView = root

        let iconView = NSImageView()
        iconView.image = AppAssets.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = UI.label("NetDisplay", size: 16, weight: .bold, align: .center)
        let desc = UI.label("把另一台电脑当作扩展显示器 / 单窗口投射", size: 11, color: Theme.sub, align: .center)
        let author = UI.label("作者：guohongbo · guohongbo@outlook.com", size: 11, color: Theme.sub, align: .center)

        // A plain clickable "GitHub" link — accent + underline, opens the repo.
        let link = UI.label("GitHub", size: 12, weight: .semibold, color: Theme.accent, align: .center)
        link.attributedStringValue = NSAttributedString(string: "GitHub", attributes: [
            .foregroundColor: Theme.accent,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .underlineStyle: NSUnderlineStyle.single.rawValue])
        let t = GenCodeTarget {
            if let url = URL(string: "https://github.com/ghbhiee/netdisplay") { NSWorkspace.shared.open(url) }
        }
        linkTarget = t
        let hit = LinkCatcher { t.fire() }
        link.addSubview(hit); hit.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hit.leadingAnchor.constraint(equalTo: link.leadingAnchor),
            hit.trailingAnchor.constraint(equalTo: link.trailingAnchor),
            hit.topAnchor.constraint(equalTo: link.topAnchor),
            hit.bottomAnchor.constraint(equalTo: link.bottomAnchor),
        ])

        let stack = UI.vstack([iconView, name, desc, author, link], spacing: 10)
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
        ])

        win = w
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

/// Transparent overlay that runs a closure on click and shows the pointing-hand
/// cursor (so a plain label reads as a link).
final class LinkCatcher: NSView {
    private let onClick: () -> Void
    init(_ onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
