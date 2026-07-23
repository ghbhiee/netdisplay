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
        b.layer?.cornerRadius = radius
        b.layer?.backgroundColor = fill?.cgColor
        if let border { b.layer?.borderColor = border.cgColor; b.layer?.borderWidth = 1 }
        b.target = target; b.action = action
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

/// NSButton that keeps its layer fill on redraw and runs a target/action.
final class ClosureButton: NSButton {
    var fillColor: NSColor? { didSet { layer?.backgroundColor = fillColor?.cgColor } }
    override func updateLayer() {
        super.updateLayer()
        if let f = fillColor { layer?.backgroundColor = f.cgColor }
    }
}
