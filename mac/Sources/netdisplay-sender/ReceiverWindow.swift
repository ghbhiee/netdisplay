import AppKit
import CoreVideo
import QuartzCore

/// A borderless-titled window that displays decoded frames. Each frame is
/// converted to a CGImage and set as the content view's layer contents (GPU
/// composited). Sizing follows the stream's display dimensions.
final class ReceiverWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var imageLayer: CALayer?
    private let renderer = FrameRenderer()
    private var configured = false
    private var baseTitle = "NetDisplay"
    private var badge: NSTextField?
    /// Called (on main) when the user closes the window — so receiving can stop.
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) { onClose?() }

    /// Bottom-left floating status badge (design §5): 「接收中 · 中转 · 3ms」.
    func setBadge(_ text: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let b = self.badge else { return }
            b.stringValue = text ?? ""
            b.isHidden = (text?.isEmpty ?? true)
        }
    }

    /// Update the window title suffix from PROJECTION_STATE (which source / paused).
    func setLabel(_ text: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.title = (text?.isEmpty == false) ? "\(self.baseTitle) · \(text!)" : self.baseTitle
        }
    }

    /// Create/size the window for the stream. Call on any thread; hops to main.
    func configure(width: Int, height: Int, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.baseTitle = title
            // Fit within the visible screen while preserving aspect ratio.
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let maxW = screen.width * 0.9, maxH = screen.height * 0.9
            let scale = min(1, min(maxW / CGFloat(width), maxH / CGFloat(height)))
            let winW = CGFloat(width) * scale, winH = CGFloat(height) * scale

            if self.window == nil {
                let win = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered, defer: false)
                win.title = title
                win.isReleasedWhenClosed = false
                win.delegate = self   // windowWillClose → onClose
                let view = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.black.cgColor
                let img = CALayer()
                img.frame = view.bounds
                img.contentsGravity = .resizeAspect
                img.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                view.layer?.addSublayer(img)
                // Bottom-left status badge (design §5).
                let badge = NSTextField(labelWithString: "")
                badge.font = .systemFont(ofSize: 11, weight: .medium)
                badge.textColor = .white
                badge.drawsBackground = true
                badge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
                badge.wantsLayer = true
                badge.layer?.cornerRadius = 6
                badge.alignment = .center
                badge.isHidden = true
                badge.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                    badge.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
                    badge.heightAnchor.constraint(equalToConstant: 22),
                ])
                self.badge = badge

                win.contentView = view
                win.center()
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.window = win
                self.imageLayer = img
            } else {
                self.window?.setContentSize(NSSize(width: winW, height: winH))
            }
            self.configured = true
        }
    }

    /// Present one decoded frame. Converts off the caller thread, sets layer
    /// contents on main.
    func present(_ pixelBuffer: CVPixelBuffer) {
        guard let cg = renderer.cgImage(from: pixelBuffer) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.imageLayer?.contents = cg
        }
    }
}
