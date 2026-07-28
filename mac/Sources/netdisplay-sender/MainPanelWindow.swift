import AppKit

/// The redesigned main panel (docs/design «主面板窗口», 430px). Renders from
/// AppModel and rebuilds on every state change. Behaviour hooks (start/stop
/// cast, receive service) live on AppModel; this class is the view layer.
final class MainPanelWindow: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var onCastTab = true
    private var qualityOpen = false
    private var chipTargets: [GenCodeTarget] = []   // retains quality-chip closure targets per rebuild
    var appList: [String] = []
    /// Receiver-side quality config (画质设置); AppController binds + persists it.
    var config = AppConfig()
    var onConfigChange: ((AppConfig) -> Void)?
    /// Live relay health, shown on the 中转设置 button (set by AppController).
    var relayStatus: RelayHealth.Status = .unknown { didSet { DispatchQueue.main.async { [weak self] in self?.rebuild() } } }
    /// Called when the user asks to pair a new device (＋ 添加设备).
    var onAddDevice: (() -> Void)?
    /// Called when the user opens 中转设置.
    var onRelaySettings: (() -> Void)?
    /// Called when the user taps ⟳ on a device row — re-probe its status now
    /// (relay presence reconnect / direct realtime probe).
    var onRefreshDevice: ((PairedDevice) -> Void)?
    /// Called whenever the projectable-window list needs to be current: opening the
    /// panel, or switching to the cast tab. The list used to be captured **once** at
    /// launch, so windows opened later never showed up — and worse, if Screen
    /// Recording wasn't granted yet at launch, the list stayed empty forever even
    /// after the user granted it (it looked like "there are no windows", not
    /// "permission missing").
    var onNeedAppList: (() -> Void)?
    private var refreshTargets: [GenCodeTarget] = []   // retain per-row refresh closures

    private let W: CGFloat = 430

    init(model: AppModel) {
        self.model = model
        super.init()
        model.onChange = { [weak self] in DispatchQueue.main.async { self?.rebuild() } }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "NetDisplay"          // name lives in the native title bar now
            w.titleVisibility = .visible
            w.titlebarAppearsTransparent = true   // blend the titlebar into the panel (no dark two-tone seam)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.backgroundColor = Theme.panel
            window = w
        }
        onNeedAppList?()          // re-enumerate windows every time the panel opens
        rebuild()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build

    private func rebuild() {
        guard let window else { return }
        chipTargets.removeAll()
        refreshTargets.removeAll()
        let root = FlippedView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.panel.cgColor

        let body = UI.vstack([], spacing: 14)
        body.translatesAutoresizingMaskIntoConstraints = false

        body.addArrangedSubview(modeSwitch())
        body.addArrangedSubview(onCastTab ? castPage() : recvPage())
        body.addArrangedSubview(devicesSection())
        body.addArrangedSubview(bottomRow())   // 中转设置 + 主题, side by side

        root.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            body.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = root
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = scroll
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: W),
        ])
        root.layoutSubtreeIfNeeded()
        let h = body.fittingSize.height + 16 + 16
        window.setContentSize(NSSize(width: W, height: min(720, max(320, h))))
    }

    // MARK: - Bottom row (中转设置 + 主题)

    private func bottomRow() -> NSView {
        let themeBtn = UI.button("◐ 主题", fill: Theme.panel2, textColor: Theme.sub, border: Theme.line,
                                 radius: 6, size: 12, weight: .regular, target: self, action: #selector(toggleTheme)).ax("theme.toggle")
        themeBtn.translatesAutoresizingMaskIntoConstraints = false
        themeBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // 中转设置 only shows when there's a relay-based pairing (user req): a purely
        // direct-paired setup has no relay to configure or probe.
        guard model.hasRelayDevice else {
            themeBtn.widthAnchor.constraint(equalToConstant: 72).isActive = true
            let row = UI.hstack([NSView(), themeBtn], spacing: 8)
            return wrapFull(row)
        }
        themeBtn.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let (label, fg, border) = relayButtonStyle()
        let relayBtn = UI.button(label, fill: .clear, textColor: fg, border: border, radius: 6,
                                 size: 12, weight: .regular, target: self, action: #selector(tapRelaySettings)).ax("relay.settings")
        relayBtn.translatesAutoresizingMaskIntoConstraints = false
        relayBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let row = UI.hstack([relayBtn, themeBtn], spacing: 8)
        relayBtn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return wrapFull(row)
    }

    /// Label + colours for the 中转设置 button, reflecting live relay health.
    private func relayButtonStyle() -> (String, NSColor, NSColor) {
        switch relayStatus {
        case .unknown:      return ("中转设置", Theme.sub, Theme.line)
        case .checking:     return ("中转设置 · 检测中…", Theme.sub, Theme.line)
        case .ok(let ms):   return ("中转 · 可用 \(ms)ms", Theme.ok, Theme.ok)
        case .unauthorized: return ("中转 · token 错误", Theme.err, Theme.err)
        case .unreachable:  return ("中转 · 连不上", Theme.err, Theme.err)
        }
    }

    // MARK: - Mode switch (segmented)

    private func modeSwitch() -> NSView {
        let holder = RoundedView(fill: Theme.panel2, radius: 8)
        let cast = segButton("投射本机", active: onCastTab, activeBg: Theme.accentWeak, activeFg: Theme.accent,
                             dot: model.role == .casting, action: #selector(tapCastTab)).ax("tab.cast")
        let recv = segButton("接收显示", active: !onCastTab, activeBg: Theme.recvWeak, activeFg: Theme.recv,
                             dot: model.role == .receiving || model.recvSvc == .waiting, action: #selector(tapRecvTab)).ax("tab.recv")
        let row = UI.hstack([cast, recv], spacing: 0)
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: holder.topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -3),
            row.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 3),
            row.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -3),
        ])
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.widthAnchor.constraint(equalToConstant: W - 32).isActive = true
        return holder
    }

    private func segButton(_ title: String, active: Bool, activeBg: NSColor, activeFg: NSColor,
                           dot: Bool, action: Selector) -> NSButton {
        let fg = active ? activeFg : Theme.sub
        let b = UI.button(title + (dot ? "  ●" : ""), fill: active ? activeBg : .clear,
                          textColor: fg, radius: 6, size: 13, weight: .semibold, target: self, action: action)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    // MARK: - Cast page

    private func castPage() -> NSView {
        let col = UI.vstack([], spacing: 8)
        col.setHuggingPriority(.defaultLow, for: .horizontal)

        switch model.role {
        case .switching:
            col.addArrangedSubview(statusStrip(icon: "⇄", iconColor: Theme.accent, title: "切换中…",
                                               titleColor: Theme.sub, border: Theme.line, bg: nil))
        case .casting:
            let peer = model.selected?.displayName ?? "对方"
            col.addArrangedSubview(castingStrip(peer: peer))
        default:
            col.addArrangedSubview(UI.label("选择投射内容", size: 12, color: Theme.sub))
            col.addArrangedSubview(sourceList())
            let enabled = model.canCast
            let btn = UI.button("开始投射", fill: enabled ? Theme.accent : Theme.line,
                                textColor: enabled ? .white : Theme.sub, radius: 8,
                                target: self, action: #selector(tapStartCast))
            btn.title = "开始投射"
            btn.attributedTitle = NSAttributedString(string: "开始投射", attributes: [
                .foregroundColor: enabled ? NSColor.white : Theme.sub,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            btn.ax("cast.start")
            fullWidth(btn, height: 34, in: col)
            col.addArrangedSubview(centeredHint("把本机画面投给对方当显示器"))
        }
        // 投射画质 lives here (the sender owns the virtual display + encoder) — it
        // applies live while casting. Shown in every cast state so it can be changed
        // mid-stream. (Moved off the receive tab, where resolution was inert.)
        col.addArrangedSubview(qualitySection())
        return wrapFull(col)
    }

    private func castingStrip(peer: String) -> NSView {
        let strip = RoundedView(fill: Theme.accentWeak, stroke: Theme.accent, radius: 8)
        let up = UI.label("⇡", size: 14, color: Theme.accent)
        let t = UI.label("正在投射给 \(peer)", size: 13, weight: .semibold)
        let s = UI.label("来源：\(sourceName())", size: 11, color: Theme.sub)
        let textCol = UI.vstack([t, s], spacing: 2)
        let stop = UI.button("停止", fill: .clear, textColor: Theme.err, border: Theme.err, radius: 6,
                             size: 12, target: self, action: #selector(tapStopCast)).ax("cast.stop")
        stop.translatesAutoresizingMaskIntoConstraints = false
        stop.heightAnchor.constraint(equalToConstant: 26).isActive = true
        stop.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        let row = UI.hstack([up, textCol, NSView(), stop], spacing: 10)
        embed(row, in: strip, pad: 11)
        return fullWidthView(strip)
    }

    private func sourceList() -> NSView {
        let col = UI.vstack([], spacing: 5)
        col.addArrangedSubview(sourceRow(icon: "🖥", name: "整块屏幕", desc: "作为对方的第二显示器",
                                         selected: model.source.isScreen, tag: "@screen"))
        // Never render "no windows" when the truth is "not allowed to look".
        if WindowPicker.screenRecordingDenied {
            col.addArrangedSubview(permissionNotice())
        } else if appList.isEmpty {
            col.addArrangedSubview(UI.label("没有可投的程序窗口（最小化的窗口不会列出）", size: 11, color: Theme.sub))
        }
        // Show every projectable window. This used to be capped at prefix(8), which
        // silently made the 9th-onward app unselectable — the list is alphabetical,
        // so whether you could project an app depended on its name. The panel lives
        // in a scroll view, so a long list is fine.
        for app in appList {
            col.addArrangedSubview(sourceRow(icon: "🪟", name: app, desc: "程序窗口",
                                             selected: model.source == .window(app), tag: app))
        }
        return wrapFull(col)
    }

    /// Shown in place of the window list when Screen Recording is denied, with a
    /// one-click jump to the exact settings pane.
    private func permissionNotice() -> NSView {
        let box = RoundedView(fill: nil, stroke: Theme.err, radius: 7)
        let t = UI.label("需要「屏幕录制」权限才能列出窗口", size: 12, color: Theme.err)
        let s = UI.label("换过签名的新版本要重新授权；授权后回到本面板会自动重新检测", size: 11, color: Theme.sub)
        s.lineBreakMode = .byWordWrapping; s.maximumNumberOfLines = 2
        let openBtn = UI.button("去设置", fill: Theme.accent, textColor: .white, radius: 6, size: 12,
                                weight: .regular, target: self, action: #selector(openScreenRecordingSettings))
        openBtn.translatesAutoresizingMaskIntoConstraints = false
        openBtn.widthAnchor.constraint(equalToConstant: 68).isActive = true
        openBtn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let col = UI.vstack([t, s], spacing: 2)
        let row = UI.hstack([col, NSView(), openBtn], spacing: 10)
        embed(row, in: box, padX: 10, padY: 8)
        return fullWidthView(box)
    }

    @objc private func openScreenRecordingSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    private func sourceRow(icon: String, name: String, desc: String, selected: Bool, tag: String) -> NSView {
        let row = RoundedView(fill: selected ? Theme.accentWeak : nil,
                              stroke: selected ? Theme.accent : Theme.line, radius: 7)
        let ic = UI.label(icon, size: 13, align: .center)
        ic.translatesAutoresizingMaskIntoConstraints = false
        ic.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let nm = UI.label(name, size: 13)
        let ds = UI.label(desc, size: 11, color: Theme.sub)
        let ck = UI.label(selected ? "✓" : "", size: 12, color: Theme.accent)
        let inner = UI.hstack([ic, nm, NSView(), ds, ck], spacing: 9)
        embed(inner, in: row, padX: 10, padY: 7)
        let click = ClickCatcher({ [weak self] in self?.model.setSource(tag == "@screen" ? .screen : .window(tag)) },
                                 label: "投射源 \(name)", id: "source.row.\(tag)")
        row.addSubview(click); click.translatesAutoresizingMaskIntoConstraints = false
        pin(click, to: row)
        return fullWidthView(row)
    }

    // MARK: - Recv page

    private func recvPage() -> NSView {
        let col = UI.vstack([], spacing: 8)
        switch model.role {
        case .switching:
            col.addArrangedSubview(statusStrip(icon: "⇄", iconColor: Theme.accent, title: "切换中…",
                                               titleColor: Theme.sub, border: Theme.line, bg: nil))
        case .receiving:
            let peer = model.selected?.displayName ?? "对方"
            col.addArrangedSubview(recvStrip(peer: peer))
        default:
            col.addArrangedSubview(recvServiceRow())
        }
        // service button (four states)
        let (label, fg, bg, border) = recvButtonStyle()
        let btn = UI.button(label, fill: bg, textColor: fg, border: border, radius: 8,
                            target: self, action: #selector(tapRecvButton)).ax("recv.toggle")
        fullWidth(btn, height: 34, in: col)
        col.addArrangedSubview(centeredHint("本机作为对方的扩展显示器 — 画质由投射方决定"))
        return wrapFull(col)
    }

    private func recvServiceRow() -> NSView {
        let strip = RoundedView(fill: nil, stroke: Theme.line, radius: 8)
        let waiting = model.recvSvc == .waiting
        let casting = model.role == .casting
        let dotColor = casting ? Theme.sub : (waiting ? Theme.recv : Theme.sub)
        let title: String, sub: String
        if casting { title = "投射中 — 接收服务不可用"; sub = "同一时刻只能投射或接收其一" }
        else if waiting { title = "等待连接中…"; sub = "以「\(localName())」待命 — 对方开始投射后自动显示" }
        else { title = "接收服务已关闭"; sub = "开启后对方才能投射到本机" }
        let d = UI.dot(dotColor)
        let t = UI.label(title, size: 13)
        let s = UI.label(sub, size: 11, color: Theme.sub)
        let col = UI.vstack([t, s], spacing: 2)
        let row = UI.hstack([d, col, NSView()], spacing: 10)
        embed(row, in: strip, padX: 12, padY: 8)
        return fullWidthView(strip)
    }

    private func recvStrip(peer: String) -> NSView {
        let strip = RoundedView(fill: Theme.recvWeak, stroke: Theme.recv, radius: 8)
        let down = UI.label("⇣", size: 14, color: Theme.recv)
        let t = UI.label("正在接收 \(peer) 的画面", size: 13, weight: .semibold)
        let s = UI.label("已在独立窗口中显示", size: 11, color: Theme.sub)
        let col = UI.vstack([t, s], spacing: 2)
        let row = UI.hstack([down, col, NSView()], spacing: 10)
        embed(row, in: strip, padX: 12, padY: 10)
        return fullWidthView(strip)
    }

    private func recvButtonStyle() -> (String, NSColor, NSColor?, NSColor?) {
        if model.role == .casting { return ("投射中 — 接收服务不可用", Theme.sub, nil, Theme.line) }
        if model.role == .receiving { return ("断开投屏（服务保持开启）", Theme.recv, .clear, Theme.recv) }
        if model.recvSvc == .waiting { return ("关闭接收服务", Theme.recv, .clear, Theme.recv) }
        return ("开启接收服务", .white, Theme.recv, nil)
    }

    // MARK: - Quality (collapsible)

    private func qualitySection() -> NSView {
        let box = RoundedView(fill: nil, stroke: Theme.line, radius: 8)
        let head = RoundedView(fill: Theme.panel2, radius: 0)
        let chev = UI.label(qualityOpen ? "▾" : "▸", size: 11, color: Theme.sub)
        let title = UI.label("投射画质", size: 13, weight: .semibold)
        let note = UI.label("投射时实时生效", size: 11, color: Theme.sub)
        let hrow = UI.hstack([chev, title, note, NSView()], spacing: 8)
        embed(hrow, in: head, padX: 12, padY: 10)
        let click = ClickCatcher { [weak self] in self?.qualityOpen.toggle(); self?.rebuild() }
        head.addSubview(click); click.translatesAutoresizingMaskIntoConstraints = false; pin(click, to: head)

        let col = UI.vstack([head], spacing: 0)
        if qualityOpen {
            let opts = UI.vstack([
                qualityGroup("分辨率", [
                    QOpt("跟随对方", config.width == nil) { self.mutateConfig { $0.width = nil; $0.height = nil } },
                    QOpt("1920×1080", config.width == 1920) { self.mutateConfig { $0.width = 1920; $0.height = 1080 } },
                    QOpt("2560×1440", config.width == 2560) { self.mutateConfig { $0.width = 2560; $0.height = 1440 } },
                ]),
                qualityGroup("缩放", [
                    QOpt("100%", config.scale == 1) { self.mutateConfig { $0.scale = 1 } },
                    QOpt("200%", config.scale == 2) { self.mutateConfig { $0.scale = 2 } },
                ]),
                qualityGroup("帧率", [
                    QOpt("30 fps", config.fps == 30) { self.mutateConfig { $0.fps = 30 } },
                    QOpt("60 fps", config.fps == 60) { self.mutateConfig { $0.fps = 60 } },
                ]),
                qualityGroup("码率", [
                    QOpt("自动", config.bitrateAuto) { self.mutateConfig { $0.bitrateAuto = true } },
                    QOpt("10 Mbps", !config.bitrateAuto && config.bitrateMbps == 10) { self.mutateConfig { $0.bitrateAuto = false; $0.bitrateMbps = 10 } },
                    QOpt("20 Mbps", !config.bitrateAuto && config.bitrateMbps == 20) { self.mutateConfig { $0.bitrateAuto = false; $0.bitrateMbps = 20 } },
                ]),
            ], spacing: 12)
            let pad = wrapPadded(opts, x: 12, y: 12, topLine: true)
            col.addArrangedSubview(pad)
        }
        embed(col, in: box, pad: 0)
        return fullWidthView(box)
    }

    /// One quality chip binding: title, whether it's the current value, and how to apply it.
    private struct QOpt {
        let title: String; let selected: Bool; let apply: () -> Void
        init(_ title: String, _ selected: Bool, _ apply: @escaping () -> Void) {
            self.title = title; self.selected = selected; self.apply = apply
        }
    }

    private func qualityGroup(_ label: String, _ options: [QOpt]) -> NSView {
        let lbl = UI.label(label, size: 12, color: Theme.sub)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: 52).isActive = true
        var chips: [NSView] = []
        for o in options {
            let t = GenCodeTarget(o.apply)
            chipTargets.append(t)   // retain for the rebuild's lifetime
            let c = UI.button(o.title, fill: o.selected ? Theme.recvWeak : .clear,
                              textColor: o.selected ? Theme.recv : Theme.sub,
                              border: o.selected ? Theme.recv : Theme.line, radius: 6, size: 12, weight: .regular,
                              target: t, action: #selector(GenCodeTarget.fire))
            c.translatesAutoresizingMaskIntoConstraints = false
            c.heightAnchor.constraint(equalToConstant: 24).isActive = true
            chips.append(c)
        }
        let chipRow = UI.hstack(chips, spacing: 6)
        return UI.hstack([lbl, chipRow], spacing: 10, align: .centerY)
    }

    /// Edit the receiver-quality config, persist via the binding, and re-render.
    private func mutateConfig(_ change: (inout AppConfig) -> Void) {
        change(&config)
        onConfigChange?(config)
        rebuild()
    }

    // MARK: - Paired devices

    private func devicesSection() -> NSView {
        let header = UI.hstack([
            UI.label("已配对设备", size: 12, weight: .semibold, color: Theme.sub),
            NSView(),
            UI.button("＋ 添加设备", fill: .clear, textColor: Theme.accent, radius: 6, size: 12,
                      weight: .regular, target: self, action: #selector(tapAddDevice)).ax("device.add"),
        ], spacing: 6)
        let col = UI.vstack([header], spacing: 8)
        if model.devices.isEmpty {
            col.addArrangedSubview(UI.label("还没有配对设备 — 点「添加设备」输入配对码", size: 11, color: Theme.sub))
        }
        for d in model.devices {
            col.addArrangedSubview(deviceRow(d))
        }
        return wrapFull(col)
    }

    private func deviceRow(_ d: PairedDevice) -> NSView {
        let selected = d.secret == model.selectedSecret
        let row = RoundedView(fill: selected ? Theme.accentWeak : nil,
                              stroke: selected ? Theme.accent : Theme.line, radius: 7)
        let radio = UI.label(selected ? "◉" : "○", size: 13, color: selected ? Theme.accent : Theme.sub)
        let active = selected && model.conn == .on
        let waiting = model.pairing.contains(d.secret)
        let online = UI.dot(active ? Theme.ok : (waiting ? Theme.sub : (d.nameKnown ? Theme.accent : Theme.sub)), size: 8)
        let name = UI.label(d.displayName, size: 13)
        // 「等待对方输入配对码…」 while announcing; live connection while projecting;
        // otherwise the connectivity probe (直连/中转), falling back to 已配对/未连接.
        let statusText: String
        if waiting { statusText = "等待对方输入配对码…" }
        else if active { statusText = model.connLabel }
        else if let ps = model.peerPresence[d.secret], let t = AppModel.peerStateLabel(ps) { statusText = t }
        else if let conn = model.connectivity[d.secret] { statusText = conn }
        else { statusText = d.nameKnown ? "已配对" : "未连接" }
        let status = UI.label(statusText, size: 11, color: Theme.sub)
        // transport badge so 直连 vs 中转 pairings are distinguishable at a glance.
        let badge = UI.label(d.usesDirect ? "直连" : "中转", size: 10,
                             color: d.usesDirect ? Theme.ok : Theme.accent)
        var items: [NSView] = [radio, online, name, NSView(), badge, status]
        // ⟳ refresh on the selected row (manual status re-probe, user req).
        if selected {
            let t = GenCodeTarget { [weak self] in self?.onRefreshDevice?(d) }
            refreshTargets.append(t)
            let refresh = UI.button("⟳", fill: .clear, textColor: Theme.sub, border: Theme.line, radius: 5,
                                    size: 12, weight: .regular, target: t, action: #selector(GenCodeTarget.fire))
                .ax("device.refresh", label: "刷新 \(d.displayName) 的状态")
            refresh.translatesAutoresizingMaskIntoConstraints = false
            refresh.widthAnchor.constraint(equalToConstant: 26).isActive = true
            refresh.heightAnchor.constraint(equalToConstant: 22).isActive = true
            items.append(refresh)
        }
        let inner = UI.hstack(items, spacing: 8)
        embed(inner, in: row, padX: 10, padY: 8)
        // Row-click selects — but only overlay the catcher on *unselected* rows, so it
        // doesn't sit on top of the selected row's ⟳ button and swallow its taps.
        if !selected {
            let click = ClickCatcher({ [weak self] in self?.model.select(secret: d.secret) },
                                     label: "选择设备 \(d.displayName)", id: "device.row.\(d.axKey)")
            row.addSubview(click); click.translatesAutoresizingMaskIntoConstraints = false; pin(click, to: row)
        }
        return fullWidthView(row)
    }

    // MARK: - Small shared pieces

    private func statusStrip(icon: String, iconColor: NSColor, title: String, titleColor: NSColor,
                             border: NSColor?, bg: NSColor?) -> NSView {
        let strip = RoundedView(fill: bg, stroke: border, radius: 8)
        let ic = UI.label(icon, size: 13, color: iconColor)
        let t = UI.label(title, size: 13, color: titleColor)
        let row = UI.hstack([ic, t, NSView()], spacing: 9)
        embed(row, in: strip, padX: 12, padY: 10)
        return fullWidthView(strip)
    }

    private func centeredHint(_ text: String) -> NSView {
        let l = UI.label(text, size: 11, color: Theme.sub, align: .center)
        return fullWidthView2(l)
    }

    // MARK: - Layout helpers

    private func embed(_ v: NSView, in parent: NSView, pad: CGFloat) { embed(v, in: parent, padX: pad, padY: pad) }
    private func embed(_ v: NSView, in parent: NSView, padX: CGFloat, padY: CGFloat) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: padX),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -padX),
            v.topAnchor.constraint(equalTo: parent.topAnchor, constant: padY),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -padY),
        ])
    }
    private func pin(_ v: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
    private func fullWidth(_ b: NSView, height: CGFloat, in col: NSStackView) {
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: height).isActive = true
        col.addArrangedSubview(b)
        b.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
    }
    /// Wrap a stack so it stretches to the panel content width.
    private func wrapFull(_ inner: NSStackView) -> NSView {
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.widthAnchor.constraint(equalToConstant: W - 32).isActive = true
        return inner
    }
    private func fullWidthView(_ v: NSView) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: W - 32).isActive = true
        return v
    }
    private func fullWidthView2(_ v: NSView) -> NSView {
        let box = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            v.topAnchor.constraint(equalTo: box.topAnchor),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: W - 32).isActive = true
        return box
    }
    private func wrapPadded(_ inner: NSView, x: CGFloat, y: CGFloat, topLine: Bool) -> NSView {
        let box = NSView()
        if topLine {
            let line = RoundedView(fill: Theme.line, radius: 0)
            line.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: box.topAnchor),
                line.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: x),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -x),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: y),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -y),
        ])
        return box
    }

    private func sourceName() -> String {
        if case .window(let a) = model.source { return a }
        return "整块屏幕"
    }
    private func localName() -> String { Host.current().localizedName ?? "本机" }

    // MARK: - Actions

    @objc private func tapCastTab() { onCastTab = true; onNeedAppList?(); rebuild() }
    @objc private func tapRecvTab() { onCastTab = false; rebuild() }
    @objc private func tapStartCast() { model.beginCast() }
    @objc private func tapStopCast() { model.stopCasting() }
    @objc private func tapRecvButton() {
        switch (model.role, model.recvSvc) {
        case (.casting, _): NSSound.beep()
        case (.receiving, _): model.receiveStopped()
        case (_, .waiting): model.stopRecvService()
        default: model.startRecvService()
        }
    }
    @objc private func tapAddDevice() { onAddDevice?() }
    @objc private func tapRelaySettings() { onRelaySettings?() }
    @objc private func toggleTheme() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Theme.override = dark ? .aqua : .darkAqua
        rebuild()
    }

    func windowWillClose(_ notification: Notification) {}
}

/// Top-down coordinate view for the panel body. Paints the panel background via
/// updateLayer so it re-resolves on light/dark appearance changes (assigning
/// Theme.panel.cgColor directly froze a light snapshot → broken dark mode).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.panel.cgColor }
}

/// A transparent overlay that runs a closure on click (for row selection).
///
/// **AX-first**: a bare NSView with `mouseDown` is invisible to the Accessibility
/// API — an external driver can see the row's text but has no way to *activate* it,
/// so the only option left is clicking raw screen coordinates. Declaring ourselves a
/// button with a stable identifier and implementing `accessibilityPerformPress`
/// makes the row semantically pressable (see docs/30-ax-conventions.md).
final class ClickCatcher: NSView {
    private let onClick: () -> Void
    init(_ onClick: @escaping () -> Void, label: String = "", id: String = "") {
        self.onClick = onClick
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if !label.isEmpty { setAccessibilityLabel(label) }
        if !id.isEmpty { setAccessibilityIdentifier(id) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

private extension NSWindow {
    /// Small no-op hook kept for readability where window chrome is tuned.
    func titidy() { self.isMovableByWindowBackground = true }
}
