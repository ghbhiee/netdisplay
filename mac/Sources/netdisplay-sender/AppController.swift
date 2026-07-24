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
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "NetDisplay")

        panel = MainPanelWindow(model: model)
        panel.config = config
        panel.onAddDevice = { [weak self] in self?.addDevice() }
        panel.onRelaySettings = { [weak self] in self?.editRelaySettings() }
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
        probeResponder.start()          // answer peers' direct-connectivity probes
        panel.show()
        checkRelay()
        probeConnectivityForSelected()
    }

    /// docs/11 §2: show how this device connects — prefer direct (only if a peer
    /// IP is set), else relay. Runs on select / launch; updates the device row.
    private func probeConnectivityForSelected() {
        guard let d = model.selected, let secret = model.selectedSecret else { return }
        let relayThen = { [weak self] in
            guard let self else { return }
            RelayHealth.check(server: self.config.relayServer,
                              token: self.config.relayToken.isEmpty ? nil : self.config.relayToken) { st in
                switch st {
                case .ok(let ms): self.model.connectivity[secret] = "中转 · 可用 \(ms)ms"
                case .unauthorized: self.model.connectivity[secret] = "中转 · token 错"
                case .unreachable: self.model.connectivity[secret] = "中转 · 连不上"
                default: break
                }
                self.model.onChange?()
            }
        }
        if let addr = d.addr, !addr.isEmpty {
            let host = addr.split(separator: ":").first.map(String.init) ?? addr
            DirectProbe.probe(host: host) { [weak self] r in
                guard let self else { return }
                switch r {
                case .ok(let ms): self.model.connectivity[secret] = "直连 · 通 \(ms)ms"; self.model.onChange?()
                case .fail: relayThen()   // direct not reachable → show relay
                }
            }
        } else {
            relayThen()   // no IP → don't probe direct
        }
    }

    /// Probe the relay (reachability + token) and reflect it on the 中转设置 button.
    private func checkRelay() {
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
        model.onSelect = { [weak self] in self?.probeConnectivityForSelected() }
    }

    private func startCasting(_ device: PairedDevice, _ source: AppModel.Source) {
        var cfg = config
        cfg.mode = .relay
        cfg.windowApp = source.isScreen ? nil : { if case .window(let a) = source { return a }; return nil }()
        config = cfg
        sender.update(cfg)
        sender.roomPairHash = device.pairHash   // register under the paired device's room
        if sender.running { sender.stop() }
        sender.start()
    }

    private func stopCasting() {
        sender.stop()
        sender.roomPairHash = nil
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
        win.onClose = { [weak self] in self?.model.receiveStopped() }   // 关窗=断开投屏
        let client = ReceiverRelayClient(
            host: rhost, port: rport, token: config.relayToken.isEmpty ? nil : config.relayToken,
            code: nil, pairHashOverride: hash,
            name: senderName, deviceId: deviceId, screen: screen, codecs: ["hevc422", "hevc", "h264"])
        client.onReady = { d, c in
            guard let d = d else { return }
            win.configure(width: d.width, height: d.height, title: "NetDisplay — \(device.displayName) 的画面")
            DispatchQueue.main.async { [weak self] in self?.model.receiveStarted() }   // 自动进入接收
        }
        client.onResize = { w, h in win.configure(width: w, height: h, title: "NetDisplay — \(device.displayName) 的画面") }
        client.onProjectionState = { a, l, k in win.setLabel(a ? (l ?? k) : "等待投射…") }
        client.onFrame = { img, _ in win.present(img) }
        receiver = client
        receiverWindow = win
        client.start()
    }

    private func stopReceiving() {
        receiver?.stop(); receiver = nil
        receiverWindow = nil
    }

    // MARK: - Dialogs

    private func addDevice() {
        guard let (code, addr) = PairDialog.run() else { return }
        let dev = DeviceStore.pairFromCode(code, addr: addr)
        model.devices = DeviceStore.load()
        model.select(secret: dev.secret)
        // Mutual pairing (docs/11, user's model): announce the room and WAIT for
        // the peer to enter the same code. "已配对" only becomes true once the
        // relay confirms the *other* machine really used the same code (with its
        // name). Until then the device shows 「等待对方输入配对码…」.
        guard let hash = dev.pairHash else { return }
        model.pairing.insert(dev.secret)
        model.onChange?()
        let pa = PairAnnounce.start(server: config.relayServer,
                                    token: config.relayToken.isEmpty ? nil : config.relayToken,
                                    pairHash: hash, deviceId: deviceId, name: senderName) { [weak self] r in
            guard let self else { return }
            switch r {
            case .confirmed(let peerId, let peerName):
                DeviceStore.promote(secret: dev.secret, deviceId: peerId, name: peerName)
                self.model.devices = DeviceStore.load()
                self.model.pairing.remove(dev.secret)
                self.announcers[dev.secret] = nil
                Log.info("pair: CONFIRMED — 已配对 \(peerName) (\(peerId))")
                self.model.onChange?()
            case .failed(let reason):
                self.model.pairing.remove(dev.secret)
                self.announcers[dev.secret] = nil
                self.pairAuthAlert(reason == "unauthorized"
                    ? "中转 token 错误。请在「中转设置」里改对 token 后重新配对。"
                    : "配对失败：\(reason)。请确认网络与中转服务器。")
                self.model.onChange?()
            }
        }
        announcers[dev.secret] = pa
    }
    private var announcers: [String: PairAnnounce] = [:]

    /// Non-blocking heads-up if pairing failed.
    private func pairAuthAlert(_ text: String) {
        let a = NSAlert(); a.messageText = "配对未完成"; a.informativeText = text
        a.addButton(withTitle: "好"); NSApp.activate(ignoringOtherApps: true); a.runModal()
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
