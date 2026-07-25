import AppKit

/// 配对弹窗 (docs/design §3, docs/11 §6) — two tabs:
///
/// - **经中转（配对码）**: type a shared 6-char code; both ends announce the derived
///   room and the relay confirms when the peer enters the same code. Requires the
///   relay to be **reachable** (the 配对 button is disabled until it is, with a
///   shortcut to 中转设置 when it isn't).
/// - **直连（对方 IP）**: type the peer's LAN IP **and** the same code. We dial
///   `IP:47800` with the code's secret while our own responder is *armed* with that
///   secret — so a pair only completes when both sides are actively pairing with the
///   same code (mirrors the relay security model).
///
/// The pairing happens **entirely inside this dialog**: 配对 → 「等待…」 while
/// announcing/dialing; the device is saved **only** when the peer confirms. Closing
/// or cancelling cancels everything and saves nothing (a code can't be exploited
/// after the window closes). Returns the confirmed PairedDevice or nil.
final class PairDialog: NSObject, NSWindowDelegate {
    private var config: AppConfig
    private let deviceId: String
    private let localName: String
    private let responder: ProbeResponder
    private let openRelaySettings: () -> AppConfig?

    private var win: NSWindow!
    private var root: FlippedView!
    private var mode = 0                // 0 = 经中转, 1 = 直连
    private var result: PairedDevice?
    private var announce: PairAnnounce?
    private var directPair: DirectPair?
    private var busy = false            // waiting for a peer → lock inputs
    private var finished = false

    // Relay reachability gating (中转 tab).
    private var relayOK = false

    // Persistent field instances (values survive tab switches).
    private let rCode = NSTextField()
    private let dAddr = NSTextField()
    private let dCode = NSTextField()
    private let statusLabel = UI.label("", size: 11, color: Theme.accent)
    private var okBtn: NSButton!
    private var genTargets: [GenCodeTarget] = []
    private var seg: NSSegmentedControl!

    private let W: CGFloat = 380

    private init(config: AppConfig, deviceId: String, name: String,
                 responder: ProbeResponder, openRelaySettings: @escaping () -> AppConfig?) {
        self.config = config; self.deviceId = deviceId; self.localName = name
        self.responder = responder; self.openRelaySettings = openRelaySettings
        super.init()
        rCode.stringValue = PairCode.generate()
        dCode.stringValue = PairCode.generate()
    }

    static func run(config: AppConfig, deviceId: String, name: String,
                    responder: ProbeResponder,
                    openRelaySettings: @escaping () -> AppConfig?) -> PairedDevice? {
        PairDialog(config: config, deviceId: deviceId, name: name,
                   responder: responder, openRelaySettings: openRelaySettings).present()
    }

    private func present() -> PairedDevice? {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 340),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "配对"; win.backgroundColor = Theme.panel; win.delegate = self
        root = FlippedView(); root.wantsLayer = true; root.layer?.backgroundColor = Theme.panel.cgColor
        win.contentView = root

        seg = NSSegmentedControl(labels: ["经中转（配对码）", "直连（对方 IP）"],
                                 trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        seg.selectedSegment = 0
        seg.translatesAutoresizingMaskIntoConstraints = false

        [rCode, dCode].forEach {
            $0.font = .monospacedSystemFont(ofSize: 18, weight: .semibold); $0.alignment = .center
            $0.placeholderString = "6 位配对码（字母+数字）"; $0.translatesAutoresizingMaskIntoConstraints = false
        }
        dAddr.placeholderString = "对方局域网 IP，例如 192.168.1.23"
        dAddr.translatesAutoresizingMaskIntoConstraints = false

        rebuild()
        NSApp.activate(ignoringOtherApps: true); win.center()
        let resp = NSApp.runModal(for: win)
        cancelInFlight()
        win.orderOut(nil)
        return resp == .OK ? result : nil
    }

    // MARK: - Layout

    private func rebuild() {
        genTargets.removeAll()
        root.subviews.forEach { $0.removeFromSuperview() }

        let cancel = UI.button("取消", fill: Theme.panel2, textColor: Theme.text, border: Theme.line,
                               radius: 6, size: 13, weight: .regular, target: self, action: #selector(cancelClicked))
        okBtn = UI.button("配对", fill: Theme.accent, textColor: .white, radius: 6, size: 13,
                          target: self, action: #selector(pairClicked))
        [cancel, okBtn].forEach { $0.translatesAutoresizingMaskIntoConstraints = false
            $0.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        let btnRow = UI.hstack([NSView(), cancel, okBtn], spacing: 8)
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        let pane = (mode == 0) ? relayPane() : directPane()
        let stack = UI.vstack([seg, pane, statusLabel, btnRow], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            seg.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pane.widthAnchor.constraint(equalTo: stack.widthAnchor),
            btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            okBtn.widthAnchor.constraint(equalToConstant: 72), cancel.widthAnchor.constraint(equalToConstant: 60),
        ])
        root.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height + 36
        win.setContentSize(NSSize(width: W, height: max(240, h)))

        seg.isEnabled = !busy
        if mode == 0 {
            if busy, let box = relayStatusView {   // announcing — don't re-probe, show static
                fillBox(box, UI.hstack([UI.label("中转 · 配对中…", size: 12, color: Theme.sub), NSView()], spacing: 8))
                okBtn.isEnabled = false
            } else {
                refreshRelayStatus()
            }
        } else {
            okBtn.isEnabled = !busy
        }
    }

    /// 经中转 pane: code + generate, plus a live relay-reachability line that gates 配对.
    private func relayPane() -> NSView {
        let gen = genButton { [weak self] in self?.rCode.stringValue = PairCode.generate() }
        let codeRow = UI.hstack([rCode, gen], spacing: 8)
        NSLayoutConstraint.activate([
            rCode.heightAnchor.constraint(equalToConstant: 34),
            gen.widthAnchor.constraint(equalToConstant: 88), gen.heightAnchor.constraint(equalToConstant: 34),
        ])
        rCode.isEnabled = !busy; gen.isEnabled = !busy
        let hint = UI.label("一方随机生成配对码，另一方输入相同的码；对方也输入后才算配对成功。",
                            size: 11, color: Theme.sub)
        hint.lineBreakMode = .byWordWrapping; hint.maximumNumberOfLines = 2
        let box = RoundedView(fill: Theme.panel2, radius: 6)
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        relayStatusView = box
        return fillWidthColumn([codeRow, box, hint], spacing: 10)
    }

    private var relayStatusView: RoundedView?

    /// 直连 pane: peer IP + code (both), no relay involved.
    private func directPane() -> NSView {
        let gen = genButton { [weak self] in self?.dCode.stringValue = PairCode.generate() }
        let codeRow = UI.hstack([dCode, gen], spacing: 8)
        NSLayoutConstraint.activate([
            dAddr.heightAnchor.constraint(equalToConstant: 30),
            dCode.heightAnchor.constraint(equalToConstant: 34),
            gen.widthAnchor.constraint(equalToConstant: 88), gen.heightAnchor.constraint(equalToConstant: 34),
        ])
        [dAddr, dCode].forEach { $0.isEnabled = !busy }; gen.isEnabled = !busy
        let hint = UI.label("直连不经中转：双方在同一局域网，都填相同配对码 + 对方 IP，各自点配对。",
                            size: 11, color: Theme.sub)
        hint.lineBreakMode = .byWordWrapping; hint.maximumNumberOfLines = 2
        let addrLabel = UI.label("对方 IP", size: 12, color: Theme.sub)
        return fillWidthColumn([addrLabel, dAddr, codeRow, hint], spacing: 8)
    }

    /// A vertical stack whose children all stretch to its width (vstack itself is
    /// .leading-aligned, so we pin each child's width explicitly).
    private func fillWidthColumn(_ children: [NSView], spacing: CGFloat) -> NSView {
        let col = UI.vstack(children, spacing: spacing)
        for c in children { c.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        return col
    }

    private func genButton(_ fire: @escaping () -> Void) -> NSButton {
        let t = GenCodeTarget(fire); genTargets.append(t)
        let b = UI.button("随机生成", fill: Theme.accentWeak, textColor: Theme.accent, radius: 6,
                          size: 12, weight: .regular, target: t, action: #selector(GenCodeTarget.fire))
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// Fill the relay-status box + gate 配对 on reachability (user req).
    private func refreshRelayStatus() {
        guard mode == 0, let box = relayStatusView else { return }
        box.subviews.forEach { $0.removeFromSuperview() }
        if config.relayServer.isEmpty {
            relayOK = false
            let l = UI.label("⚠️ 尚未设置中转服务", size: 12, color: Theme.err)
            let setup = UI.button("设置中转", fill: Theme.accent, textColor: .white, radius: 6, size: 12,
                                  weight: .regular, target: self, action: #selector(tapRelaySetup))
            setup.translatesAutoresizingMaskIntoConstraints = false
            setup.widthAnchor.constraint(equalToConstant: 84).isActive = true
            setup.heightAnchor.constraint(equalToConstant: 26).isActive = true
            fillBox(box, UI.hstack([l, NSView(), setup], spacing: 8))
            okBtn.isEnabled = false
            return
        }
        relayOK = false; okBtn.isEnabled = false
        fillBox(box, UI.hstack([UI.label("中转 · 检测中…", size: 12, color: Theme.sub), NSView()], spacing: 8))
        RelayHealth.check(server: config.relayServer,
                          token: config.relayToken.isEmpty ? nil : config.relayToken) { [weak self] st in
            guard let self, self.mode == 0, let box = self.relayStatusView else { return }
            box.subviews.forEach { $0.removeFromSuperview() }
            switch st {
            case .ok(let ms):
                self.relayOK = true
                self.fillBox(box, UI.hstack([UI.label("中转 · 可用 \(ms)ms", size: 12, color: Theme.ok), NSView()], spacing: 8))
                self.okBtn.isEnabled = !self.busy
            default:
                self.relayOK = false; self.okBtn.isEnabled = false
                let txt = (st == .unauthorized) ? "中转 · token 错误" : "中转 · 连不上"
                let setup = UI.button("中转设置", fill: .clear, textColor: Theme.accent, border: Theme.line,
                                      radius: 6, size: 12, weight: .regular, target: self, action: #selector(self.tapRelaySetup))
                setup.translatesAutoresizingMaskIntoConstraints = false
                setup.widthAnchor.constraint(equalToConstant: 84).isActive = true
                setup.heightAnchor.constraint(equalToConstant: 26).isActive = true
                self.fillBox(box, UI.hstack([UI.label(txt, size: 12, color: Theme.err), NSView(), setup], spacing: 8))
            }
        }
    }

    private func fillBox(_ box: RoundedView, _ inner: NSView) {
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if busy { sender.selectedSegment = mode; return }   // don't switch mid-pairing
        mode = sender.selectedSegment
        statusLabel.stringValue = ""
        rebuild()
    }

    @objc private func tapRelaySetup() {
        if let newCfg = openRelaySettings() { config = newCfg }
        refreshRelayStatus()
    }

    @objc private func pairClicked() {
        mode == 0 ? pairViaRelay() : pairDirect()
    }

    /// 经中转: announce the code's room; complete when the peer enters the same code.
    private func pairViaRelay() {
        guard relayOK else {
            statusLabel.textColor = Theme.err
            statusLabel.stringValue = "中转不可用，请先在「中转设置」里配置"
            return
        }
        let code = PairCode.normalize(rCode.stringValue)
        guard code.count == 6 else {
            statusLabel.textColor = Theme.err; statusLabel.stringValue = "配对码错误（应为 6 位字母或数字）"; return
        }
        let secret = PairCode.secret(fromCode: code)
        guard let hash = PairStore.pairHash(fromSecret: secret) else { return }
        enterBusy("⏳ 等待对方输入配对码…（关闭窗口即取消）")
        announce = PairAnnounce.start(server: config.relayServer,
                                      token: config.relayToken.isEmpty ? nil : config.relayToken,
                                      pairHash: hash, deviceId: deviceId, name: localName) { [weak self] r in
            guard let self else { return }
            switch r {
            case .confirmed(let peerId, let peerName):
                self.succeed(PairedDevice(deviceId: peerId, secret: secret, code: code,
                                          name: peerName, transport: "relay"))
            case .failed(let reason):
                self.announce = nil
                self.fail(reason == "unauthorized" ? "中转 token 错误，请到「中转设置」改" : "配对失败：\(reason)")
            }
        }
    }

    /// 直连: arm our responder with the code's secret + dial the peer's IP with it.
    /// Completes when either side's PAIR_HELLO lands.
    private func pairDirect() {
        let addr = dAddr.stringValue.trimmingCharacters(in: .whitespaces)
        let host = addr.split(separator: ":").first.map(String.init) ?? addr
        guard !host.isEmpty else {
            statusLabel.textColor = Theme.err; statusLabel.stringValue = "请输入对方的 IP 地址"; return
        }
        let code = PairCode.normalize(dCode.stringValue)
        guard code.count == 6 else {
            statusLabel.textColor = Theme.err; statusLabel.stringValue = "配对码错误（应为 6 位字母或数字）"; return
        }
        let secret = PairCode.secret(fromCode: code)
        enterBusy("⏳ 正在直连 \(host)…（对方也需在直连页填相同码）")

        // Arm the responder so an inbound PAIR_HELLO with this code is accepted.
        responder.armedSecret = secret
        responder.onArmedPair = { [weak self] peerId, peerName, peerAddr in
            DispatchQueue.main.async {
                self?.succeed(PairedDevice(deviceId: peerId, secret: secret, code: code,
                                           name: peerName, addr: peerAddr, transport: "direct"))
            }
        }
        // And dial the peer ourselves.
        DirectPair.pair(host: host, deviceId: deviceId, name: localName, secret: secret) { [weak self] r in
            guard let self else { return }
            switch r {
            case .paired(let peerId, let peerName):
                self.succeed(PairedDevice(deviceId: peerId, secret: secret, code: code,
                                          name: peerName, addr: addr, transport: "direct"))
            case .fail(let reason):
                // Our dial failed — but the peer may still dial us (armed). Keep waiting,
                // just surface the hint; the window stays open until confirm or cancel.
                self.statusLabel.textColor = Theme.sub
                self.statusLabel.stringValue = "直连拨号未通（\(reason)）— 仍在等待对方拨入…"
            }
        }
    }

    private func enterBusy(_ msg: String) {
        busy = true
        statusLabel.textColor = Theme.accent; statusLabel.stringValue = msg
        rebuild()
    }

    private func succeed(_ dev: PairedDevice) {
        if finished { return }; finished = true
        result = dev
        cancelInFlight()
        NSApp.stopModal(withCode: .OK)
    }

    private func fail(_ msg: String) {
        busy = false
        statusLabel.textColor = Theme.err; statusLabel.stringValue = msg
        rebuild()
    }

    /// Stop any announce/dial + disarm the responder (security: nothing lingers).
    private func cancelInFlight() {
        announce?.cancel(); announce = nil
        directPair = nil
        responder.armedSecret = nil
        responder.onArmedPair = nil
    }

    @objc private func cancelClicked() {
        cancelInFlight()
        NSApp.stopModal(withCode: .cancel)
    }

    func windowWillClose(_ notification: Notification) {
        cancelInFlight()
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
