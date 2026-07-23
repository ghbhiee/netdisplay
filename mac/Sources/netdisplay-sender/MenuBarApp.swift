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

    // Receive mode (this Mac as a target screen) — the symmetric-app half.
    private var receiver: ReceiverRelayClient?       // relay receive
    private var receiverDirect: ReceiverSession?     // direct receive (dial peer :47800)
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

        let status = NSMenuItem(title: controller.state.short, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        // Relay pairing code — prominent + copyable.
        if cfg.mode == .relay, case .waitingForPeer(let code) = controller.state {
            let codeItem = NSMenuItem(title: "配对码：\(code)（点按复制）", action: #selector(copyCode), keyEquivalent: "")
            codeItem.target = self
            menu.addItem(codeItem)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: controller.running ? "停止投送" : "开始投送",
                                action: #selector(toggleStartStop), keyEquivalent: "s")
        toggle.target = self
        menu.addItem(toggle)

        // Receive mode: this Mac acts as a target screen (symmetric app).
        let recv = NSMenuItem(title: receiving ? "停止接收投射" : "接收投射（本机作目标屏）…",
                              action: receiving ? #selector(stopReceiving) : #selector(startReceivingPrompt),
                              keyEquivalent: "r")
        recv.target = self
        menu.addItem(recv)
        menu.addItem(.separator())

        // Projection source: whole desktop vs a single window
        let srcMenu = NSMenu()
        let desktop = choice("整个桌面（扩展屏）", checked: cfg.windowApp == nil, action: #selector(setDesktopSource))
        srcMenu.addItem(desktop)
        if !appList.isEmpty { srcMenu.addItem(.separator()) }
        for app in appList {
            let it = choice(app, checked: cfg.windowApp == app, action: #selector(setWindowSource(_:)))
            it.representedObject = app
            srcMenu.addItem(it)
        }
        srcMenu.addItem(.separator())
        let refresh = NSMenuItem(title: "刷新窗口列表", action: #selector(refreshApps), keyEquivalent: "")
        refresh.target = self
        srcMenu.addItem(refresh)
        let srcItem = NSMenuItem(title: "投射源：" + (cfg.windowApp ?? "整个桌面"), action: nil, keyEquivalent: "")
        srcItem.submenu = srcMenu
        menu.addItem(srcItem)
        if cfg.windowApp != nil {
            let st = NSMenuItem(title: "移到扩展屏（窗口离开主屏，需辅助功能权限）",
                                action: #selector(toggleStage), keyEquivalent: "")
            st.target = self
            st.state = cfg.stage ? .on : .off
            menu.addItem(st)
        }
        menu.addItem(.separator())

        // Connection — one consolidated settings dialog (方式 + 地址/中转/token).
        let modeName: String
        switch cfg.mode { case .auto: modeName = "自动"; case .direct: modeName = "直连"; case .relay: modeName = "中转" }
        let connItem = NSMenuItem(title: "连接设置：\(modeName) …", action: #selector(editConnectionSettings), keyEquivalent: "")
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
        alert.informativeText = "两端配一次即可。自动 = 并行试直连+中转、先通者胜；token 留空 = 不鉴权。"
        func label(_ t: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: t); l.frame = NSRect(x: 0, y: y, width: W, height: 18); return l
        }
        func field(_ y: CGFloat, _ v: String, _ ph: String, mono: Bool = false) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: y, width: W, height: 24))
            f.stringValue = v; f.placeholderString = ph
            if mono { f.font = .monospacedSystemFont(ofSize: 12, weight: .regular); f.cell?.wraps = false; f.cell?.isScrollable = true }
            return f
        }
        let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 150, width: W, height: 26))
        modePopup.addItems(withTitles: ["自动（推荐）", "直连（同网 / USB4）", "中转（跨网络）"])
        modePopup.selectItem(at: cfg.mode == .auto ? 0 : (cfg.mode == .direct ? 1 : 2))
        let peer = field(100, cfg.peerHost, "对方地址（直连/自动用），如 10.77.0.2 或 192.168.x.x")
        let server = field(50, cfg.relayServer, "15.tokencv.com:47700")
        let token = field(0, cfg.relayToken, "中转 token（可 Cmd+V 粘贴，留空=不鉴权）", mono: true)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 200))
        let views: [NSView] = [label("连接方式", 178), modePopup,
                               label("对方地址（直连 / 自动）", 126), peer,
                               label("中转服务器", 76), server,
                               label("访问 token", 26), token]
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
        if cfg.mode == .direct {
            alert.informativeText = "直连模式：拨号对方地址（端口 :\(cfg.listenPort)）。"
            field.stringValue = cfg.peerHost
            field.placeholderString = "对方地址，如 10.77.0.2 或 192.168.x.x"
        } else {
            alert.informativeText = "中转 \(cfg.relayServer)：输入发送端显示的 6 位配对码；已持久配对可留空。"
            field.placeholderString = "6 位配对码（已配对可留空）"
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
            startReceiving(directHost: input, code: "")
        } else {
            startReceiving(directHost: nil, code: input)
        }
    }

    /// Report this Mac's main-display pixel size + the codecs it can decode.
    private func receiverScreen() -> HelloReceiver.Screen {
        let cfg = controller.config
        return HelloReceiver.Screen(
            width: Int(CGDisplayPixelsWide(CGMainDisplayID())),
            height: Int(CGDisplayPixelsHigh(CGMainDisplayID())),
            scale: 1, fps: cfg.fps, bitrateMbps: cfg.bitrateAuto ? nil : cfg.bitrateMbps)
    }

    private func startReceiving(directHost: String?, code: String) {
        let cfg = controller.config
        let screen = receiverScreen()
        let codecs = ["hevc422", "hevc", "h264"]
        let win = ReceiverWindow()
        // Window wiring shared by both transports.
        let onReady: (HelloAck.Display?, VideoCodec) -> Void = { d, c in
            guard let d = d else { return }
            win.configure(width: d.width, height: d.height,
                          title: "NetDisplay 接收 — \(d.width)×\(d.height) \(c.wire)")
        }
        let onProj: (Bool, String?, String?) -> Void = { a, l, k in win.setLabel(a ? (l ?? k) : "等待投射…") }
        let onResize: (Int, Int) -> Void = { w, h in win.configure(width: w, height: h, title: "NetDisplay 接收 — \(w)×\(h)") }
        let onFrame: (CVImageBuffer, CMTime) -> Void = { img, _ in win.present(img) }

        if let host = directHost {
            let s = ReceiverSession(host: host, port: UInt16(cfg.listenPort),
                                    name: senderName, deviceId: deviceId, screen: screen, codecs: codecs)
            s.onReady = onReady; s.onProjectionState = onProj; s.onResize = onResize; s.onFrame = onFrame
            s.onClosed = { [weak self] in DispatchQueue.main.async { self?.stopReceiving() } }
            receiverDirect = s
            s.start()
        } else {
            let parts = cfg.relayServer.split(separator: ":")
            let rhost = String(parts.first ?? "15.tokencv.com")
            let rport = UInt16(parts.count > 1 ? Int(parts[1]) ?? Int(Proto.relayPort) : Int(Proto.relayPort))
            let client = ReceiverRelayClient(host: rhost, port: rport,
                                             token: cfg.relayToken.isEmpty ? nil : cfg.relayToken,
                                             code: code.isEmpty ? nil : code,
                                             name: senderName, deviceId: deviceId, screen: screen, codecs: codecs)
            client.onReady = onReady; client.onProjectionState = onProj; client.onResize = onResize; client.onFrame = onFrame
            receiver = client
            client.start()
        }
        receiverWindow = win
        receiving = true
        rebuildMenu()
    }

    @objc private func stopReceiving() {
        receiver?.stop(); receiver = nil
        receiverDirect?.close(); receiverDirect = nil
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
