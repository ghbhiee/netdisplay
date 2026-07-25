import AppKit
import CoreVideo
import CoreMedia
import CoreGraphics

/// The redesigned app: a menu-bar presence + the main panel, driving the real
/// SenderController / receiver through AppModel's hooks. Replaces the old
/// MenuBarApp (dropped — no legacy 直连/中转 picker).
final class AppController: NSObject, NSApplicationDelegate {
    private let senderName: String
    private let deviceId: String
    private let model = AppModel()
    private let sender: SenderController
    private var config = AppConfig.load()
    private var statusItem: NSStatusItem!
    private var panel: MainPanelWindow!
    private var tray: TrayMenu!

    // Receive side
    private var receiver: ReceiverRelayClient?
    private var receiverWindow: ReceiverWindow?
    private let probeResponder = ProbeResponder()   // always-on :47800 PROBE→PROBE_ACK (docs/11 §2)

    init(senderName: String, deviceId: String) {
        self.senderName = senderName
        self.deviceId = deviceId
        self.sender = SenderController(senderName: senderName, deviceId: deviceId, config: config)
        super.init()
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = AppAssets.icon, let small = icon.copy() as? NSImage {
            small.size = NSSize(width: 18, height: 18)   // the NetDisplay (Windows) logo, colored
            small.isTemplate = false
            statusItem.button?.image = small
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "NetDisplay")
        }

        panel = MainPanelWindow(model: model)
        panel.config = config
        panel.onAddDevice = { [weak self] in self?.addDevice() }
        panel.onRelaySettings = { [weak self] in self?.editRelaySettings() }
        panel.onRefreshDevice = { [weak self] d in self?.refreshDevice(d) }
        panel.onConfigChange = { [weak self] cfg in
            self?.config = cfg
            self?.sender.update(cfg)   // persists + applies live if streaming
        }

        tray = TrayMenu(model: model)
        tray.onAddDevice = { [weak self] in self?.addDevice() }
        tray.onRelaySettings = { [weak self] in self?.editRelaySettings() }
        tray.onOpenPanel = { [weak self] in self?.panel.show() }
        statusItem.menu = tray.menu   // click the icon → the four-section menu

        wireModel()
        refreshAppList()
        probeResponder.myDeviceId = deviceId
        probeResponder.myName = senderName
        probeResponder.start()          // answer peers' direct-connectivity probes + direct pairing
        panel.show()
        checkRelay()
        probeConnectivityForSelected()
        restartPresence()               // FIX: presence must start for the already-selected
                                        // device at launch, not only when the user re-selects —
                                        // otherwise the peer never sees our state (docs/11 §5).
    }

    /// docs/11 §2: show how this device connects. Direct pairings realtime-probe
    /// their IP; relay pairings let the persistent presence channel report status
    /// (no self-pair storm). Runs on select / launch / manual refresh.
    private func probeConnectivityForSelected() {
        guard let d = model.selected else { return }
        if d.usesDirect { probeDirect(d) }
        // relay device → presence.onConnected drives connectivity; nothing to do here.
    }

    /// Realtime direct probe of a device's IP (user req: 直连要实时探测).
    private func probeDirect(_ d: PairedDevice) {
        guard let addr = d.addr, !addr.isEmpty else { return }
        let secret = d.secret
        let host = addr.split(separator: ":").first.map(String.init) ?? addr
        DirectProbe.probe(host: host) { [weak self] r in
            guard let self else { return }
            switch r {
            case .ok(let ms): self.model.connectivity[secret] = "直连 · 通 \(ms)ms"
            case .fail:       self.model.connectivity[secret] = "直连 · 不通"
            }
            self.model.onChange?()
        }
    }

    /// ⟳ on a device row: re-probe its status right now.
    private func refreshDevice(_ d: PairedDevice) {
        if d.usesDirect {
            model.connectivity[d.secret] = "直连 · 探测中…"; model.onChange?()
            probeDirect(d)
        } else {
            // Relay: force a fresh presence connection (re-checks relay + peer online)
            // and re-measure the 中转设置 button.
            model.connectivity[d.secret] = "中转 · 检测中…"; model.onChange?()
            restartPresence()
            checkRelay()
        }
    }

    /// Probe the relay (reachability + token) and reflect it on the 中转设置 button.
    /// Skipped entirely when no paired device uses the relay (user req).
    private func checkRelay() {
        guard model.hasRelayDevice else { panel.relayStatus = .unknown; return }
        guard !config.relayServer.isEmpty else { panel.relayStatus = .unknown; return }
        panel.relayStatus = .checking
        RelayHealth.check(server: config.relayServer,
                          token: config.relayToken.isEmpty ? nil : config.relayToken) { [weak self] st in
            self?.panel.relayStatus = st
        }
    }

    // MARK: - Model → real sender/receiver

    private func wireModel() {
        model.onStartCasting = { [weak self] device, source in self?.startCasting(device, source) }
        model.onStopCasting = { [weak self] in self?.stopCasting() }
        model.onStartRecvService = { [weak self] in self?.startReceiving() }
        model.onStopRecvService = { [weak self] in self?.stopReceiving() }
        model.onSelect = { [weak self] in self?.probeConnectivityForSelected(); self?.restartPresence() }
    }

    // MARK: - Presence (docs/11 §5)
    private var presence: PresenceClient?
    private func restartPresence() {
        presence?.stop(); presence = nil
        guard let d = model.selected, d.usesRelay, let hash = d.pairHash, let secret = model.selectedSecret else { return }
        let p = PresenceClient(server: config.relayServer,
                               token: config.relayToken.isEmpty ? nil : config.relayToken,
                               pairHash: hash, deviceId: deviceId, name: senderName, state: model.presenceState)
        p.onPeer = { [weak self] st in self?.model.peerPresence[secret] = st; self?.model.onChange?() }
        // The presence channel doubles as the live relay-health signal (docs/11 §5):
        // it's connected ⇒ relay reachable + token OK, so we skip repeated self-pairs.
        p.onConnected = { [weak self] ms in
            self?.panel.relayStatus = .ok(ms: ms)
            self?.model.connectivity[secret] = "中转 · 可用 \(ms)ms"
            self?.model.onChange?()
        }
        p.onUnauthorized = { [weak self] in self?.panel.relayStatus = .unauthorized }
        presence = p
        p.start()
    }
    /// Push our current state to the peer (call after any role change).
    private func pushPresence() { presence?.update(state: model.presenceState) }

    private func startCasting(_ device: PairedDevice, _ source: AppModel.Source) {
        var cfg = config
        cfg.mode = .relay
        cfg.windowApp = source.isScreen ? nil : { if case .window(let a) = source { return a }; return nil }()
        config = cfg
        sender.update(cfg)
        sender.roomPairHash = device.pairHash   // register under the paired device's room
        if sender.running { sender.stop() }
        sender.start()
        pushPresence()
    }

    private func stopCasting() {
        sender.stop()
        sender.roomPairHash = nil
        pushPresence()
    }

    private func startReceiving() {
        guard let device = model.selected, let hash = device.pairHash else { return }
        let parts = config.relayServer.split(separator: ":")
        let rhost = String(parts.first ?? "15.tokencv.com")
        let rport = UInt16(parts.count > 1 ? Int(parts[1]) ?? Int(Proto.relayPort) : Int(Proto.relayPort))
        let screen = HelloReceiver.Screen(
            width: Int(CGDisplayPixelsWide(CGMainDisplayID())),
            height: Int(CGDisplayPixelsHigh(CGMainDisplayID())),
            scale: 1, fps: config.fps, bitrateMbps: config.bitrateAuto ? nil : config.bitrateMbps)
        let win = ReceiverWindow()
        win.onClose = { [weak self] in self?.model.stopRecvService() }   // 用户关窗 = 停止接收(不再重连)
        let client = ReceiverRelayClient(
            host: rhost, port: rport, token: config.relayToken.isEmpty ? nil : config.relayToken,
            code: nil, pairHashOverride: hash,
            name: senderName, deviceId: deviceId, screen: screen, codecs: ["hevc422", "hevc", "h264"])
        client.onReady = { [weak self] d, c in
            guard let d = d else { return }
            win.configure(width: d.width, height: d.height, title: "NetDisplay — \(device.displayName) 的画面")
            let transport = self?.model.connectivity[device.secret] ?? "中转"
            win.setBadge("接收中 · \(transport) · \(c.wire)")
            DispatchQueue.main.async { self?.model.receiveStarted() }   // 自动进入接收
        }
        client.onResize = { w, h in win.configure(width: w, height: h, title: "NetDisplay — \(device.displayName) 的画面") }
        client.onProjectionState = { a, l, k in win.setLabel(a ? (l ?? k) : "等待投射…") }
        client.onFrame = { img, _ in win.present(img) }
        client.onStreamEnded = { [weak self] in
            win.closeWindow()               // 投射方停止 → 关掉接收窗口
            self?.model.receiveStopped()    // 回待命；接收服务保持，对方再投时自动重开窗口
        }
        receiver = client
        receiverWindow = win
        client.start()
        pushPresence()
    }

    private func stopReceiving() {
        receiver?.stop(); receiver = nil
        receiverWindow?.closeWindow()
        receiverWindow = nil
        pushPresence()
    }

    // MARK: - Dialogs

    private func addDevice() {
        // The dialog announces/dials + waits internally and returns a device ONLY once
        // the peer confirmed with the same code (docs/11 §1/§6 + the security ask). If
        // the user closes/cancels, nothing is saved — the code can't be exploited.
        // `openRelaySettings` lets the 中转 tab configure the relay inline when unset.
        guard let dev = PairDialog.run(
            config: config, deviceId: deviceId, name: senderName, responder: probeResponder,
            openRelaySettings: { [weak self] () -> AppConfig? in
                guard let self, let newCfg = RelaySettingsDialog.run(config: self.config) else { return nil }
                self.config = newCfg
                self.sender.update(newCfg)
                self.checkRelay()
                return newCfg
            }) else { return }
        DeviceStore.upsert(dev)
        model.devices = DeviceStore.load()
        model.select(secret: dev.secret)
        Log.info("pair: CONFIRMED — 已配对 \(dev.name) [\(dev.transport)]")
    }

    private func editRelaySettings() {
        guard let newCfg = RelaySettingsDialog.run(config: config) else { return }
        config = newCfg
        sender.update(newCfg)
        checkRelay()   // re-probe with the new server/token
    }

    // MARK: - Sources / menu bar

    private func refreshAppList() {
        Task {
            let apps = await WindowPicker.projectableApps()
            await MainActor.run { self.panel.appList = apps; self.tray.appList = apps }
        }
    }

    /// Accessory apps have no main menu, so Cmd+C/V don't reach dialog fields.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
    }
}
