import AppKit

/// 配对弹窗 (docs/design §3). The mutual-pairing announce lives **entirely inside
/// this dialog** (user's requirement + security): 配对 → 「等待对方输入配对码…」 while
/// announcing; the device is saved **only** when the peer confirms. Closing or
/// cancelling the dialog **cancels the announce and saves nothing** — a code can't
/// linger or be exploited after you close the window. Returns the confirmed
/// PairedDevice (with the peer's name) or nil.
final class PairDialog: NSObject, NSWindowDelegate {
    private let config: AppConfig
    private let deviceId: String
    private let localName: String
    private var win: NSWindow!
    private let codeField = NSTextField()
    private let addrField = NSTextField()
    private let statusLabel = UI.label("", size: 11, color: Theme.accent)
    private var okBtn: NSButton!
    private var genBtn: NSButton!
    private var genTarget: GenCodeTarget?
    private var announce: PairAnnounce?
    private var result: PairedDevice?

    private init(config: AppConfig, deviceId: String, name: String) {
        self.config = config; self.deviceId = deviceId; self.localName = name
        super.init()
    }

    static func run(config: AppConfig, deviceId: String, name: String) -> PairedDevice? {
        PairDialog(config: config, deviceId: deviceId, name: name).present()
    }

    private func present() -> PairedDevice? {
        let W: CGFloat = 360
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 280),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "配对"; win.backgroundColor = Theme.panel; win.delegate = self
        let root = FlippedView(); root.wantsLayer = true; root.layer?.backgroundColor = Theme.panel.cgColor
        win.contentView = root

        codeField.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        codeField.alignment = .center
        codeField.placeholderString = "6 位配对码（字母+数字）"
        codeField.stringValue = PairCode.generate()
        codeField.translatesAutoresizingMaskIntoConstraints = false

        let gt = GenCodeTarget { [weak self] in self?.codeField.stringValue = PairCode.generate() }
        genTarget = gt
        genBtn = UI.button("随机生成", fill: Theme.accentWeak, textColor: Theme.accent, radius: 6,
                           size: 12, weight: .regular, target: gt, action: #selector(GenCodeTarget.fire))
        genBtn.translatesAutoresizingMaskIntoConstraints = false

        addrField.placeholderString = "对方地址（可选，可留空由对方填写）"
        addrField.translatesAutoresizingMaskIntoConstraints = false

        let title = UI.label("配对码 — 两台电脑输入相同的码", size: 12, weight: .semibold, color: Theme.sub)
        let hint1 = UI.label("一方随机生成后，另一方输入相同的配对码。对方也输入后才算配对成功。", size: 11, color: Theme.sub)

        let cancel = UI.button("取消", fill: Theme.panel2, textColor: Theme.text, border: Theme.line,
                               radius: 6, size: 13, weight: .regular, target: self, action: #selector(cancelClicked))
        okBtn = UI.button("配对", fill: Theme.accent, textColor: .white, radius: 6, size: 13,
                          target: self, action: #selector(pairClicked))
        [cancel, okBtn].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.heightAnchor.constraint(equalToConstant: 30).isActive = true }

        let codeRow = UI.hstack([codeField, genBtn], spacing: 8); codeRow.translatesAutoresizingMaskIntoConstraints = false
        let btnRow = UI.hstack([NSView(), cancel, okBtn], spacing: 8); btnRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = UI.vstack([title, codeRow, hint1, addrField, statusLabel, btnRow], spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            codeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codeField.heightAnchor.constraint(equalToConstant: 34),
            genBtn.widthAnchor.constraint(equalToConstant: 88), genBtn.heightAnchor.constraint(equalToConstant: 34),
            addrField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            addrField.heightAnchor.constraint(equalToConstant: 26),
            okBtn.widthAnchor.constraint(equalToConstant: 72), cancel.widthAnchor.constraint(equalToConstant: 60),
        ])

        NSApp.activate(ignoringOtherApps: true); win.center()
        let resp = NSApp.runModal(for: win)
        announce?.cancel(); announce = nil   // always stop announcing on any exit
        win.orderOut(nil)
        return resp == .OK ? result : nil
    }

    @objc private func pairClicked() {
        let code = PairCode.normalize(codeField.stringValue)
        guard code.count == 6 else {
            statusLabel.textColor = Theme.err
            statusLabel.stringValue = "配对码错误（应为 6 位字母或数字）"
            return
        }
        let secret = PairCode.secret(fromCode: code)
        guard let hash = PairStore.pairHash(fromSecret: secret) else { return }
        let addr = addrField.stringValue.trimmingCharacters(in: .whitespaces)
        codeField.isEditable = false; genBtn.isEnabled = false; okBtn.isEnabled = false
        statusLabel.textColor = Theme.accent
        statusLabel.stringValue = "⏳ 等待对方输入配对码…（关闭窗口即取消）"
        announce = PairAnnounce.start(server: config.relayServer,
                                      token: config.relayToken.isEmpty ? nil : config.relayToken,
                                      pairHash: hash, deviceId: deviceId, name: localName) { [weak self] r in
            guard let self else { return }
            switch r {
            case .confirmed(let peerId, let peerName):
                self.result = PairedDevice(deviceId: peerId, secret: secret, code: code,
                                           name: peerName, addr: addr.isEmpty ? nil : addr)
                NSApp.stopModal(withCode: .OK)
            case .failed(let reason):
                self.announce = nil
                self.codeField.isEditable = true; self.genBtn.isEnabled = true; self.okBtn.isEnabled = true
                self.statusLabel.textColor = Theme.err
                self.statusLabel.stringValue = reason == "unauthorized"
                    ? "中转 token 错误，请到「中转设置」改" : "配对失败：\(reason)"
            }
        }
    }

    @objc private func cancelClicked() {
        announce?.cancel(); announce = nil
        NSApp.stopModal(withCode: .cancel)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window cancels the announce and saves nothing (security).
        announce?.cancel(); announce = nil
        if NSApp.modalWindow == win { NSApp.stopModal(withCode: .cancel) }
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
