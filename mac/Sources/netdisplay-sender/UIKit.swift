import AppKit

/// Small AppKit building blocks styled from the design tokens (Theme).

/// A layer-backed view with a fill, optional border, and corner radius.
final class RoundedView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var strokeWidth: CGFloat = 1
    var radius: CGFloat = 8 { didSet { needsDisplay = true } }

    init(fill: NSColor? = nil, stroke: NSColor? = nil, radius: CGFloat = 8) {
        self.fill = fill; self.stroke = stroke; self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.backgroundColor = fill?.cgColor
        layer?.borderColor = stroke?.cgColor
        layer?.borderWidth = stroke == nil ? 0 : strokeWidth
    }
    override var wantsUpdateLayer: Bool { true }
}

extension NSView {
    /// Tag a control with a stable accessibility identifier so external drivers can
    /// find it by name instead of by screen coordinates (docs/30-ax-conventions.md).
    /// Returns self so it chains: `UI.button(...).ax("cast.start")`.
    @discardableResult
    func ax(_ id: String, label: String? = nil) -> Self {
        setAccessibilityIdentifier(id)
        if let label { setAccessibilityLabel(label) }
        return self
    }
}

enum UI {
    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = Theme.text, align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = align
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// A filled or outlined pill button running a Swift closure.
    static func button(_ title: String, fill: NSColor?, textColor: NSColor,
                       border: NSColor? = nil, radius: CGFloat = 8,
                       size: CGFloat = 13, weight: NSFont.Weight = .semibold,
                       target: AnyObject, action: Selector) -> NSButton {
        let b = ClosureButton()
        b.title = title
        b.isBordered = false
        b.wantsLayer = true
        b.contentTintColor = textColor
        b.font = .systemFont(ofSize: size, weight: weight)
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: textColor, .font: NSFont.systemFont(ofSize: size, weight: weight)])
        // Store the *dynamic* colors and resolve them inside updateLayer (correct
        // appearance) — assigning .cgColor here freezes a light-appearance snapshot,
        // which is why dark mode used to render light buttons.
        b.corner = radius
        b.fillColor = fill
        b.borderColor = border
        b.borderWidth = border == nil ? 0 : 1
        b.target = target; b.action = action
        b.needsDisplay = true
        return b
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.spacing = spacing; s.alignment = align
        return s
    }
    static func vstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.spacing = spacing; s.alignment = .leading
        return s
    }

    /// A small circular status dot.
    static func dot(_ color: NSColor, size: CGFloat = 8) -> RoundedView {
        let d = RoundedView(fill: color, radius: size / 2)
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: size).isActive = true
        d.heightAnchor.constraint(equalToConstant: size).isActive = true
        return d
    }
}

/// Tiny @objc target so an NSButton can run a Swift closure (e.g. 随机生成).
final class GenCodeTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// NSButton that re-resolves its fill/border on every draw cycle (so dynamic
/// Theme colors track light/dark appearance changes) and runs a target/action.
final class ClosureButton: NSButton {
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 0
    var corner: CGFloat = 0
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = corner
        layer?.backgroundColor = fillColor?.cgColor       // resolves under effectiveAppearance
        layer?.borderColor = borderColor?.cgColor
        layer?.borderWidth = borderColor == nil ? 0 : borderWidth
    }
}
