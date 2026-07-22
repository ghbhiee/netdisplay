import AppKit

/// A status-bar (menu-bar) app wrapping the sender, with live-editable config.
/// Runs as an accessory app (no Dock icon).
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let controller: SenderController
    private var statusItem: NSStatusItem!
    private var lastCode: String?
    private var appList: [String] = []

    init(senderName: String, deviceId: String) {
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

        // Mode
        menu.addItem(sectionHeader("模式"))
        menu.addItem(choice("中转（relay，跨网络）", checked: cfg.mode == .relay, action: #selector(setModeRelay)))
        menu.addItem(choice("直连（direct，USB4/局域网）", checked: cfg.mode == .direct, action: #selector(setModeDirect)))
        if cfg.mode == .relay {
            let rs = NSMenuItem(title: "中转设置：\(cfg.relayServer)" + (cfg.relayToken.isEmpty ? "（无 token）" : "（有 token）") + " …",
                                action: #selector(editRelaySettings), keyEquivalent: "")
            rs.target = self
            menu.addItem(rs)
        }
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
    @objc private func editRelaySettings() {
        let alert = NSAlert()
        alert.messageText = "中转服务器设置"
        alert.informativeText = "地址（host:port）与访问 token（公网 relay 鉴权，留空=不鉴权）"
        let server = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        server.stringValue = controller.config.relayServer
        server.placeholderString = "relay.example.com:47700"
        let token = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        token.stringValue = controller.config.relayToken
        token.placeholderString = "token"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        box.addSubview(server); box.addSubview(token)
        alert.accessoryView = box
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            mutate { $0.relayServer = server.stringValue.trimmingCharacters(in: .whitespaces)
                     $0.relayToken = token.stringValue.trimmingCharacters(in: .whitespaces) }
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
