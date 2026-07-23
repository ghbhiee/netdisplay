import AppKit

/// The menu-bar dropdown (docs/design §2). Native NSMenu rebuilt from AppModel on
/// each open. Four sections: 投射/接收服务 · 投射内容 · 已配对设备 · 显示, then footer.
final class TrayMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    let menu = NSMenu()
    var appList: [String] = []
    var onAddDevice: (() -> Void)?
    var onRelaySettings: (() -> Void)?
    var onOpenPanel: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func header(_ t: String) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.attributedTitle = NSAttributedString(string: t, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        return it
    }
    private func item(_ t: String, _ sel: Selector?, enabled: Bool = true, checked: Bool = false,
                      obj: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
        it.target = self
        it.isEnabled = enabled && sel != nil
        it.state = checked ? .on : .off
        it.representedObject = obj
        return it
    }

    private func rebuild() {
        menu.removeAllItems()

        // ── 第一节：投射 / 接收服务 ──
        switch model.role {
        case .casting:
            menu.addItem(item("■ 投射中 · \(sourceName()) — 断开", #selector(stopCast)))
        case .receiving:
            menu.addItem(item("投射（接收中不可用）", nil, enabled: false))
        default:
            if model.canCast { menu.addItem(item("▶ 投射：开始", #selector(startCast))) }
            else { menu.addItem(item(model.selected == nil ? "投射（先选设备）" : "投射（接收服务开着）", nil, enabled: false)) }
        }
        switch (model.role, model.recvSvc) {
        case (.casting, _): menu.addItem(item("接收服务（投射中不可用）", nil, enabled: false))
        case (.receiving, _): menu.addItem(item("■ 接收投屏中 — 断开", #selector(stopReceive)))
        case (_, .waiting): menu.addItem(item("接收服务 · 等待连接（点关闭）", #selector(stopRecvSvc)))
        default: menu.addItem(item("启动接收服务", #selector(startRecvSvc)))
        }

        // ── 第二节：投射内容（仅投射模式：接收服务关闭、未在接收、已选设备）──
        // 开启接收服务后隐藏投射内容（屏幕/程序），与投射互斥。
        if model.recvSvc == .off, model.role != .receiving, model.selected != nil {
            menu.addItem(.separator())
            menu.addItem(header("投射内容 · 最近窗口"))
            menu.addItem(item("整块屏幕", #selector(pickSource), checked: model.source.isScreen, obj: "@screen"))
            for app in appList.prefix(8) {
                menu.addItem(item(app, #selector(pickSource), checked: model.source == .window(app), obj: app))
            }
        }

        // ── 第三节：已配对设备 ──
        menu.addItem(.separator())
        let devHeader = model.recvSvc == .off ? "投射目标 · 已配对设备"
                      : (model.role == .receiving ? "接收中 · 已配对设备" : "等待接收 · 已配对设备")
        menu.addItem(header(devHeader))
        if model.devices.isEmpty {
            menu.addItem(item("＋ 添加设备…", #selector(addDevice)))
        } else {
            for d in model.devices {
                let sel = d.secret == model.selectedSecret
                let status = d.isPending ? "待配对" : model.connLabel
                let it = item("\(d.displayName) · \(status)", #selector(selectDevice), checked: sel, obj: d.secret)
                let sub = NSMenu()
                let rm = NSMenuItem(title: "解除配对…", action: #selector(removeDevice), keyEquivalent: "")
                rm.target = self; rm.representedObject = d.secret
                sub.addItem(rm)
                it.submenu = sub
                menu.addItem(it)
            }
            menu.addItem(item("＋ 添加设备…", #selector(addDevice)))
        }

        // ── 第四节：显示（作为显示器时）──
        menu.addItem(.separator())
        menu.addItem(header("显示（作为显示器时）"))
        menu.addItem(item("画质设置（主面板）…", #selector(openPanel)))

        // ── 尾部 ──
        menu.addItem(.separator())
        menu.addItem(item("中转设置…", #selector(relaySettings)))
        menu.addItem(item("打开主面板", #selector(openPanel)))
        menu.addItem(item("退出 NetDisplay", #selector(quit)))
    }

    private func sourceName() -> String {
        if case .window(let a) = model.source { return a }
        return "整块屏幕"
    }

    // MARK: - Actions
    @objc private func startCast() { model.beginCast() }
    @objc private func stopCast() { model.stopCasting() }
    @objc private func startRecvSvc() { model.startRecvService() }
    @objc private func stopRecvSvc() { model.stopRecvService() }
    @objc private func stopReceive() { model.receiveStopped() }
    @objc private func pickSource(_ s: NSMenuItem) {
        guard let tag = s.representedObject as? String else { return }
        model.setSource(tag == "@screen" ? .screen : .window(tag))
    }
    @objc private func selectDevice(_ s: NSMenuItem) { model.select(secret: s.representedObject as? String) }
    @objc private func removeDevice(_ s: NSMenuItem) {
        guard let secret = s.representedObject as? String else { return }
        DeviceStore.remove(secret: secret)
        model.devices = DeviceStore.load()
        if model.selectedSecret == secret { model.select(secret: model.devices.first?.secret) }
    }
    @objc private func addDevice() { onAddDevice?() }
    @objc private func relaySettings() { onRelaySettings?() }
    @objc private func openPanel() { onOpenPanel?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
