import AppKit

/// 配对弹窗 (docs/design §3, 360px): both machines type the same 6-digit code;
/// one side can generate it. Optional peer address is just a direct-connect hint.
/// Returns (code, addr?) or nil if cancelled.
enum PairDialog {
    static func run() -> (code: String, addr: String?)? {
        let W: CGFloat = 360
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 260),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "配对"
        win.backgroundColor = Theme.panel
        let root = FlippedView(); root.wantsLayer = true
        root.layer?.backgroundColor = Theme.panel.cgColor
        win.contentView = root

        let codeField = NSTextField(frame: .zero)
        codeField.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        codeField.alignment = .center
        codeField.placeholderString = "6 位配对码"
        codeField.stringValue = String(format: "%06d", Int.random(in: 100000...999999))
        codeField.translatesAutoresizingMaskIntoConstraints = false

        let genTarget = GenCodeTarget { codeField.stringValue = String(format: "%06d", Int.random(in: 100000...999999)) }
        let gen = UI.button("随机生成", fill: Theme.accentWeak, textColor: Theme.accent, radius: 6,
                            size: 12, weight: .regular, target: genTarget, action: #selector(GenCodeTarget.fire))
        gen.translatesAutoresizingMaskIntoConstraints = false

        let addrField = NSTextField(frame: .zero)
        addrField.placeholderString = "对方地址（可选，可留空由对方填写）"
        addrField.translatesAutoresizingMaskIntoConstraints = false

        let title = UI.label("配对码 — 两台电脑输入相同的码", size: 12, weight: .semibold, color: Theme.sub)
        let hint1 = UI.label("一方随机生成后，另一方输入相同的配对码。", size: 11, color: Theme.sub)
        let hint2 = UI.label("双方都留空对方地址时，将通过中转服务器建立连接。", size: 11, color: Theme.sub)

        let cancel = UI.button("取消", fill: Theme.panel2, textColor: Theme.text, border: Theme.line,
                               radius: 6, size: 13, weight: .regular, target: DialogButtons.shared, action: #selector(DialogButtons.cancel))
        let ok = UI.button("配对", fill: Theme.accent, textColor: .white, radius: 6, size: 13,
                           target: DialogButtons.shared, action: #selector(DialogButtons.ok))
        [cancel, ok].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.heightAnchor.constraint(equalToConstant: 30).isActive = true }

        let codeRow = UI.hstack([codeField, gen], spacing: 8)
        codeRow.translatesAutoresizingMaskIntoConstraints = false
        let btnRow = UI.hstack([NSView(), cancel, ok], spacing: 8)
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = UI.vstack([title, codeRow, hint1, addrField, hint2, btnRow], spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            codeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codeField.heightAnchor.constraint(equalToConstant: 34),
            gen.widthAnchor.constraint(equalToConstant: 88), gen.heightAnchor.constraint(equalToConstant: 34),
            addrField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            addrField.heightAnchor.constraint(equalToConstant: 26),
            ok.widthAnchor.constraint(equalToConstant: 72), cancel.widthAnchor.constraint(equalToConstant: 60),
        ])

        NSApp.activate(ignoringOtherApps: true)
        win.center()
        let resp = NSApp.runModal(for: win)
        win.orderOut(nil)
        guard resp == .OK else { return nil }
        let code = PairCode.normalize(codeField.stringValue)
        guard code.count == 6 else { return nil }
        let addr = addrField.stringValue.trimmingCharacters(in: .whitespaces)
        return (code, addr.isEmpty ? nil : addr)
    }
}

/// 中转设置弹窗 (docs/design §4): relay server, token, force-relay. Edits AppConfig.
enum RelaySettingsDialog {
    static func run(config: AppConfig) -> AppConfig? {
        let W: CGFloat = 340
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 220),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "中转设置"; win.backgroundColor = Theme.panel
        let root = FlippedView(); root.wantsLayer = true; root.layer?.backgroundColor = Theme.panel.cgColor
        win.contentView = root

        let server = NSTextField(); server.stringValue = config.relayServer; server.placeholderString = "15.tokencv.com:47700"
        let token = NSSecureTextField(); token.stringValue = config.relayToken; token.placeholderString = "访问 Token（留空=不鉴权）"
        [server, token].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let cancel = UI.button("取消", fill: Theme.panel2, textColor: Theme.text, border: Theme.line, radius: 6,
                               size: 13, weight: .regular, target: DialogButtons.shared, action: #selector(DialogButtons.cancel))
        let ok = UI.button("保存", fill: Theme.accent, textColor: .white, radius: 6, size: 13,
                           target: DialogButtons.shared, action: #selector(DialogButtons.ok))
        [cancel, ok].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        let btnRow = UI.hstack([NSView(), cancel, ok], spacing: 8); btnRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = UI.vstack([
            UI.label("中转服务器地址", size: 12, color: Theme.sub), server,
            UI.label("访问 Token", size: 12, color: Theme.sub), token,
            btnRow,
        ], spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            server.widthAnchor.constraint(equalTo: stack.widthAnchor), server.heightAnchor.constraint(equalToConstant: 26),
            token.widthAnchor.constraint(equalTo: stack.widthAnchor), token.heightAnchor.constraint(equalToConstant: 26),
            btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ok.widthAnchor.constraint(equalToConstant: 72), cancel.widthAnchor.constraint(equalToConstant: 60),
        ])
        NSApp.activate(ignoringOtherApps: true); win.center()
        let resp = NSApp.runModal(for: win)
        win.orderOut(nil)
        guard resp == .OK else { return nil }
        var c = config
        c.relayServer = server.stringValue.trimmingCharacters(in: .whitespaces)
        c.relayToken = token.stringValue.trimmingCharacters(in: .whitespaces)
        return c
    }
}

/// Shared modal OK/Cancel target (dialogs are modal & serial, so a singleton is fine).
final class DialogButtons: NSObject {
    static let shared = DialogButtons()
    @objc func ok() { NSApp.stopModal(withCode: .OK) }
    @objc func cancel() { NSApp.stopModal(withCode: .cancel) }
}
