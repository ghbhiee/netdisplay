import AppKit
import CoreGraphics
import CoreVideo
import CoreMedia

/// A status-bar (menu-bar) app wrapping the sender, with live-editable config.
/// Runs as an accessory app (no Dock icon).
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let controller: SenderController
    private let senderName: String
    private let deviceId: String
    private var statusItem: NSStatusItem!
    private var lastCode: String?
    private var appList: [String] = []
    private var dialogGenTarget: GenCodeTarget?   // retains the 生成 button target during the settings modal

    // Receive mode (this Mac as a target screen) — the symmetric-app half.
    private var receiver: ReceiverRelayClient?       // relay receive
    private var receiverDirect: ReceiverSession?     // direct receive (dial peer :47800)
    private var receiverAuto: ReceiverAuto?          // auto: race direct + relay
    private var receiverWindow: ReceiverWindow?
    private var receiving = false

    init(senderName: String, deviceId: String) {
        self.senderName = senderName
        self.deviceId = deviceId
        self.controller = SenderController(senderName: senderName, deviceId: deviceId)
        super.init()
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "NetDisplay")
        }
        controller.onState = { [weak self] state in
            DispatchQueue.main.async { self?.onState(state) }
        }
        installEditMenu()   // so Cmd+C/V/X/A work in text fields (dialogs)
        rebuildMenu()
        refreshAppList()
        if ProcessInfo.processInfo.environment["NETDISPLAY_AUTOSTART"] == "1" {
            controller.start()
        }
    }

    private func refreshAppList() {
        Task {
            let apps = await WindowPicker.projectableApps()
            await MainActor.run { self.appList = apps; self.rebuildMenu() }
        }
    }

    private func onState(_ state: SenderState) {
        Log.info("app state: \(state.short)")
        if case .waitingForPeer(let code) = state { lastCode = code }
        if case .streaming = state { /* keep last code for reference */ }
        // Reflect status in the button tooltip + a title glyph when streaming.
        if let button = statusItem.button {
            button.toolTip = "NetDisplay — \(state.short)"
            switch state {
            case .streaming: button.image = NSImage(systemSymbolName: "display.and.arrow.down", accessibilityDescription: nil)
            default: button.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
            }
        }
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let cfg = controller.config
        let menu = NSMenu()

        // Role-aware status header (待命 / 投射出去 / 接收显示) — the unified control.
        let roleStatus: String
        if receiving {
            roleStatus = "◀ 接收中（本机作目标屏，显示对方画面）"
        } else if controller.running {
            roleStatus = "▶ 投射中：\(cfg.windowApp ?? "整个桌面") → 对方"
        } else {
            roleStatus = "○ 待命 · 已就绪"
        }
        let status = NSMenuItem(title: roleStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let detail = NSMenuItem(title: "　" + controller.state.short, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        // Relay pairing code — prominent + copyable.
        if cfg.mode != .direct, case .waitingForPeer(let code) = controller.state {
            let codeItem = NSMenuItem(title: "配对码：\(code)（点按复制）", action: #selector(copyCode), keyEquivalent: "")
            codeItem.target = self
            menu.addItem(codeItem)
        }
        menu.addItem(.separator())

        // 投射本机 ▸ ：投射源 + 开始/停止，收敛成一个控件（不再散落的 toggle + 独立投射源）。
        let projMenu = NSMenu()
        projMenu.addItem(sectionHeader("投射源"))
        projMenu.addItem(choice("整个桌面（扩展屏）", checked: cfg.windowApp == nil, action: #selector(setDesktopSource)))
        for app in appList {
            let it = choice(app, checked: cfg.windowApp == app, action: #selector(setWindowSource(_:)))
            it.representedObject = app
            projMenu.addItem(it)
        }
        let refresh = NSMenuItem(title: "刷新窗口列表", action: #selector(refreshApps), keyEquivalent: "")
        refresh.target = self
        projMenu.addItem(refresh)
        if cfg.windowApp != nil {
            let st = NSMenuItem(title: "移到扩展屏（窗口离开主屏，需辅助功能权限）",
                                action: #selector(toggleStage), keyEquivalent: "")
            st.target = self
            st.state = cfg.stage ? .on : .off
            projMenu.addItem(st)
        }
        projMenu.addItem(.separator())
        let startStop = NSMenuItem(title: controller.running ? "■ 停止投射" : "▶ 开始投射（源：\(cfg.windowApp ?? "整屏")）",
                                   action: #selector(toggleStartStop), keyEquivalent: "s")
        startStop.target = self
        projMenu.addItem(startStop)
        let projItem = NSMenuItem(title: "投射本机（把本机投给对方）▸", action: nil, keyEquivalent: "")
        projItem.submenu = projMenu
        menu.addItem(projItem)

        // 接收投射（本机作目标屏，显示对方画面）
        let recv = NSMenuItem(title: receiving ? "■ 停止接收" : "接收投射（本机作目标屏，显示对方画面）…",
                              action: receiving ? #selector(stopReceiving) : #selector(startReceivingPrompt),
                              keyEquivalent: "r")
        recv.target = self
        menu.addItem(recv)
        menu.addItem(.separator())

        // Connection — one consolidated settings dialog (方式 + 地址/中转/token).
        let modeName: String
        switch cfg.mode { case .auto: modeName = "自动"; case .direct: modeName = "直连"; case .relay: modeName = "中转" }
        let codeSuffix = (cfg.mode != .direct && !cfg.pairCode.isEmpty) ? " · 配对码 \(cfg.pairCode)" : ""
        let connItem = NSMenuItem(title: "连接设置：\(modeName)\(codeSuffix) …", action: #selector(editConnectionSettings), keyEquivalent: "")
        connItem.target = self
        menu.addItem(connItem)
        menu.addItem(.separator())

        // Scale
        menu.addItem(sectionHeader("缩放（治字太小；越大字越大，画面仍清晰）"))
        for s in [1, 2, 3] {
            let it = choice("\(s)x" + (s == 2 ? "（推荐）" : ""), checked: cfg.scale == s, action: #selector(setScale(_:)))
            it.tag = s
            menu.addItem(it)
        }
        menu.addItem(.separator())

        // Bitrate
        menu.addItem(sectionHeader("码率（越高越清晰，中转受公网上行限制）"))
        menu.addItem(choice("自动（听对端设置）", checked: cfg.bitrateAuto, action: #selector(setBitrateAuto)))
        for m in [10, 20, 40, 60, 80] {
            let it = choice("\(m) Mbps", checked: !cfg.bitrateAuto && cfg.bitrateMbps == m, action: #selector(setBitrate(_:)))
            it.tag = m
            menu.addItem(it)
        }
        menu.addItem(.separator())

        // FPS
        menu.addItem(sectionHeader("帧率（低码率时降到 30/24 更清）"))
        for f in [24, 30, 60] {
            let it = choice("\(f) fps", checked: cfg.fps == f, action: #selector(setFps(_:)))
            it.tag = f
            menu.addItem(it)
        }
        menu.addItem(.separator())

        // Resolution
        menu.addItem(sectionHeader("分辨率"))
        let follow = choice("跟随对端上报", checked: cfg.width == nil, action: #selector(setResFollow))
        menu.addItem(follow)
        for (w, h) in [(2560, 1600), (1920, 1200), (1600, 1000), (1280, 800)] {
            let it = choice("\(w)×\(h)", checked: cfg.width == w && cfg.height == h, action: #selector(setResolution(_:)))
            it.representedObject = [w, h]
            menu.addItem(it)
        }
        menu.addItem(.separator())

        // Quality toggle
        let q = NSMenuItem(title: "清晰优先（同码率更锐，编码稍慢）", action: #selector(toggleQuality), keyEquivalent: "")
        q.target = self
        q.state = cfg.quality ? .on : .off
        menu.addItem(q)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 NetDisplay", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Accessory (menu-bar) apps have no main menu, so standard editing shortcuts
    /// (Cmd+C/V/X/A) don't reach text fields in dialogs. Install a minimal Edit
    /// menu whose first-responder actions route to the focused field editor.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func choice(_ title: String, checked: Bool, action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.state = checked ? .on : .off
        return it
    }

    // MARK: - Actions

    @objc private func toggleStartStop() {
        if controller.running { controller.stop() } else { controller.start() }
        rebuildMenu()
    }
    @objc private func setDesktopSource() { mutate { $0.windowApp = nil } }
    @objc private func setWindowSource(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        mutate { $0.windowApp = app }
    }
    @objc private func refreshApps() { refreshAppList() }
    @objc private func toggleStage() { mutate { $0.stage.toggle() } }
    /// One consolidated connection settings dialog (对齐 10-ux-model)：连接方式(自动/直连/中转)
    /// + 对方地址(直连/自动) + 中转服务器 + token。发送和接收共用这一处。
    @objc private func editConnectionSettings() {
        let cfg = controller.config
        let W: CGFloat = 520
        let alert = NSAlert()
        alert.messageText = "连接设置"
        alert.informativeText = "两端配一次即可，全部保存在本地、下次启动不用再填。\n配对码：两端填同一个（自定或点『生成』），投射端和接收端都用它，固定不变。token 留空=不鉴权。"
        func label(_ t: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: t); l.frame = NSRect(x: 0, y: y, width: W, height: 18); return l
        }
        func field(_ y: CGFloat, _ w: CGFloat, _ v: String, _ ph: String, mono: Bool = false) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: y, width: w, height: 24))
            f.stringValue = v; f.placeholderString = ph
            if mono { f.font = .monospacedSystemFont(ofSize: 12, weight: .regular); f.cell?.wraps = false; f.cell?.isScrollable = true }
            return f
        }
        let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 234, width: W, height: 26))
        modePopup.addItems(withTitles: ["自动（推荐）", "直连（同网 / USB4）", "中转（跨网络）"])
        modePopup.selectItem(at: cfg.mode == .auto ? 0 : (cfg.mode == .direct ? 1 : 2))
        // 配对码 + 生成按钮（同一行）
        let pairField = field(184, W - 96, cfg.pairCode, "配对码，两端填同一个（如 8888）", mono: true)
        let genBtn = NSButton(frame: NSRect(x: W - 88, y: 182, width: 88, height: 26))
        genBtn.title = "生成"; genBtn.bezelStyle = .rounded
        genBtn.setButtonType(.momentaryPushIn)
        let gen = GenCodeTarget { pairField.stringValue = String(format: "%06d", Int.random(in: 100000...999999)) }
        genBtn.target = gen; genBtn.action = #selector(GenCodeTarget.fire)
        dialogGenTarget = gen   // keep the button's target alive for the modal's lifetime
        let peer = field(130, W, cfg.peerHost, "对方地址（直连/自动用），如 10.77.0.2 或 192.168.x.x")
        let server = field(76, W, cfg.relayServer, "15.tokencv.com:47700")
        let token = field(6, W, cfg.relayToken, "中转 token（可 Cmd+V 粘贴，留空=不鉴权）", mono: true)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 264))
        let views: [NSView] = [label("连接方式", 262), modePopup,
                               label("配对码（两端相同，保存本地、启动不变）", 208), pairField, genBtn,
                               label("对方地址（直连 / 自动）", 156), peer,
                               label("中转服务器", 100), server,
                               label("访问 token", 30), token]
        views.forEach(box.addSubview)
        alert.accessoryView = box
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let modes: [AppConfig.Mode] = [.auto, .direct, .relay]
            let picked = modes[max(0, min(2, modePopup.indexOfSelectedItem))]
            mutate {
                $0.mode = picked
                $0.pairCode = pairField.stringValue.trimmingCharacters(in: .whitespaces)
                $0.peerHost = peer.stringValue.trimmingCharacters(in: .whitespaces)
                $0.relayServer = server.stringValue.trimmingCharacters(in: .whitespaces)
                $0.relayToken = token.stringValue.trimmingCharacters(in: .whitespaces)
            }
        }
    }
    @objc private func setModeRelay() { mutate { $0.mode = .relay } }
    @objc private func setModeDirect() { mutate { $0.mode = .direct } }
    @objc private func setScale(_ sender: NSMenuItem) { mutate { $0.scale = sender.tag } }
    @objc private func setBitrate(_ sender: NSMenuItem) { mutate { $0.bitrateMbps = sender.tag; $0.bitrateAuto = false } }
    @objc private func setBitrateAuto() { mutate { $0.bitrateAuto = true } }
    @objc private func setFps(_ sender: NSMenuItem) { mutate { $0.fps = sender.tag } }
    @objc private func toggleQuality() { mutate { $0.quality.toggle() } }
    @objc private func setResFollow() { mutate { $0.width = nil; $0.height = nil } }
    @objc private func setResolution(_ sender: NSMenuItem) {
        guard let wh = sender.representedObject as? [Int], wh.count == 2 else { return }
        mutate { $0.width = wh[0]; $0.height = wh[1] }
    }
    @objc private func copyCode() {
        guard let code = lastCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    // MARK: - Receive (this Mac as a target screen)

    @objc private func startReceivingPrompt() {
        let cfg = controller.config
        let alert = NSAlert()
        alert.messageText = "接收投射（本机作目标屏）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        switch cfg.mode {
        case .direct:
            alert.informativeText = "直连：拨号对方地址（端口 :\(cfg.listenPort)）。"
            field.stringValue = cfg.peerHost
            field.placeholderString = "对方地址，如 10.77.0.2 或 192.168.x.x"
        case .relay:
            alert.informativeText = "中转 \(cfg.relayServer)：与投射端填同一个配对码（已在设置里保存则自动带出，直接开始即可）。"
            field.stringValue = cfg.pairCode          // saved code pre-filled → no re-typing
            field.placeholderString = "配对码（和投射端相同）"
        case .auto:
            alert.informativeText = "自动：并行试直连（对方地址=\(cfg.peerHost.isEmpty ? "未填，跳过直连" : cfg.peerHost)）与中转，先握手成功者胜。配对码和投射端相同（已保存则自动带出）。"
            field.stringValue = cfg.pairCode          // saved code pre-filled → no re-typing
            field.placeholderString = "配对码（和投射端相同）"
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "开始接收")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespaces)
        if cfg.mode == .direct {
            guard !input.isEmpty else { return }
            mutate { $0.peerHost = input }   // remember the peer address
        } else if !input.isEmpty && input != cfg.pairCode {
            mutate { $0.pairCode = input }   // remember the pairing code → no re-typing next time
        }
        startReceiving(code: cfg.mode == .direct ? "" : input)
    }

    /// Report this Mac's main-display pixel size + the codecs it can decode.
    private func receiverScreen() -> HelloReceiver.Screen {
        let cfg = controller.config
        return HelloReceiver.Screen(
            width: Int(CGDisplayPixelsWide(CGMainDisplayID())),
            height: Int(CGDisplayPixelsHigh(CGMainDisplayID())),
            scale: 1, fps: cfg.fps, bitrateMbps: cfg.bitrateAuto ? nil : cfg.bitrateMbps)
    }

    private func startReceiving(code: String) {
        let cfg = controller.config
        let screen = receiverScreen()
        let codecs = ["hevc422", "hevc", "h264"]
        let win = ReceiverWindow()
        win.onClose = { [weak self] in self?.stopReceiving() }   // 关窗口 → 停接收
        // Window wiring shared by all transports.
        let onReady: (HelloAck.Display?, VideoCodec) -> Void = { d, c in
            guard let d = d else { return }
            win.configure(width: d.width, height: d.height,
                          title: "NetDisplay 接收 — \(d.width)×\(d.height) \(c.wire)")
        }
        let onProj: (Bool, String?, String?) -> Void = { a, l, k in win.setLabel(a ? (l ?? k) : "等待投射…") }
        let onResize: (Int, Int) -> Void = { w, h in win.configure(width: w, height: h, title: "NetDisplay 接收 — \(w)×\(h)") }
        let onFrame: (CVImageBuffer, CMTime) -> Void = { img, _ in win.present(img) }

        func makeDirect() -> ReceiverSession {
            ReceiverSession(host: cfg.peerHost, port: UInt16(cfg.listenPort),
                            name: senderName, deviceId: deviceId, screen: screen, codecs: codecs)
        }
        func makeRelay() -> ReceiverRelayClient {
            let parts = cfg.relayServer.split(separator: ":")
            let rhost = String(parts.first ?? "15.tokencv.com")
            let rport = UInt16(parts.count > 1 ? Int(parts[1]) ?? Int(Proto.relayPort) : Int(Proto.relayPort))
            return ReceiverRelayClient(host: rhost, port: rport,
                                       token: cfg.relayToken.isEmpty ? nil : cfg.relayToken,
                                       code: code.isEmpty ? nil : code,
                                       name: senderName, deviceId: deviceId, screen: screen, codecs: codecs)
        }

        switch cfg.mode {
        case .direct:
            let s = makeDirect()
            s.onReady = onReady; s.onProjectionState = onProj; s.onResize = onResize; s.onFrame = onFrame
            s.onClosed = { [weak self] in DispatchQueue.main.async { self?.stopReceiving() } }
            receiverDirect = s; s.start()
        case .relay:
            let c = makeRelay()
            c.onReady = onReady; c.onProjectionState = onProj; c.onResize = onResize; c.onFrame = onFrame
            receiver = c; c.start()
        case .auto:
            // Race a direct dial (if peer address set) + a relay join; app-layer win.
            let auto = ReceiverAuto(direct: cfg.peerHost.isEmpty ? nil : makeDirect(), relay: makeRelay())
            auto.onReady = onReady; auto.onProjectionState = onProj; auto.onResize = onResize; auto.onFrame = onFrame
            receiverAuto = auto; auto.start()
        }
        receiverWindow = win
        receiving = true
        rebuildMenu()
    }

    @objc private func stopReceiving() {
        receiver?.stop(); receiver = nil
        receiverDirect?.close(); receiverDirect = nil
        receiverAuto?.stop(); receiverAuto = nil
        receiverWindow = nil
        receiving = false
        rebuildMenu()
    }
    @objc private func quit() {
        controller.stop()
        NSApplication.shared.terminate(nil)
    }

    /// Edit the config and apply it live (restarts the stream if running).
    private func mutate(_ change: (inout AppConfig) -> Void) {
        var cfg = controller.config
        change(&cfg)
        controller.update(cfg)
        rebuildMenu()
    }
}

/// Tiny @objc target so an NSButton can run a Swift closure (the 生成 code button).
final class GenCodeTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
