import AppKit

/// The redesigned main panel (docs/design «主面板窗口», 430px). Renders from
/// AppModel and rebuilds on every state change. Behaviour hooks (start/stop
/// cast, receive service) live on AppModel; this class is the view layer.
final class MainPanelWindow: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var onCastTab = true
    private var qualityOpen = false
    var appList: [String] = []
    /// Live relay health, shown on the 中转设置 button (set by AppController).
    var relayStatus: RelayHealth.Status = .unknown { didSet { DispatchQueue.main.async { [weak self] in self?.rebuild() } } }
    /// Called when the user asks to pair a new device (＋ 添加设备).
    var onAddDevice: (() -> Void)?
    /// Called when the user opens 中转设置.
    var onRelaySettings: (() -> Void)?

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
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.backgroundColor = Theme.panel
            window = w
        }
        rebuild()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build

    private func rebuild() {
        guard let window else { return }
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
        let (label, fg, border) = relayButtonStyle()
        let relayBtn = UI.button(label, fill: .clear, textColor: fg, border: border, radius: 6,
                                 size: 12, weight: .regular, target: self, action: #selector(tapRelaySettings))
        relayBtn.translatesAutoresizingMaskIntoConstraints = false
        relayBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let themeBtn = UI.button("◐ 主题", fill: Theme.panel2, textColor: Theme.sub, border: Theme.line,
                                 radius: 6, size: 12, weight: .regular, target: self, action: #selector(toggleTheme))
        themeBtn.translatesAutoresizingMaskIntoConstraints = false
        themeBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        themeBtn.widthAnchor.constraint(equalToConstant: 72).isActive = true

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
                             dot: model.role == .casting, action: #selector(tapCastTab))
        let recv = segButton("接收显示", active: !onCastTab, activeBg: Theme.recvWeak, activeFg: Theme.recv,
                             dot: model.role == .receiving || model.recvSvc == .waiting, action: #selector(tapRecvTab))
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
            fullWidth(btn, height: 34, in: col)
            col.addArrangedSubview(centeredHint("把本机画面投给对方当显示器"))
        }
        return wrapFull(col)
    }

    private func castingStrip(peer: String) -> NSView {
        let strip = RoundedView(fill: Theme.accentWeak, stroke: Theme.accent, radius: 8)
        let up = UI.label("⇡", size: 14, color: Theme.accent)
        let t = UI.label("正在投射给 \(peer)", size: 13, weight: .semibold)
        let s = UI.label("来源：\(sourceName())", size: 11, color: Theme.sub)
        let textCol = UI.vstack([t, s], spacing: 2)
        let stop = UI.button("停止", fill: .clear, textColor: Theme.err, border: Theme.err, radius: 6,
                             size: 12, target: self, action: #selector(tapStopCast))
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
        for app in appList.prefix(8) {
            col.addArrangedSubview(sourceRow(icon: "🪟", name: app, desc: "程序窗口",
                                             selected: model.source == .window(app), tag: app))
        }
        return wrapFull(col)
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
        let click = ClickCatcher { [weak self] in self?.model.setSource(tag == "@screen" ? .screen : .window(tag)) }
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
                            target: self, action: #selector(tapRecvButton))
        fullWidth(btn, height: 34, in: col)
        col.addArrangedSubview(centeredHint("本机作为对方的扩展显示器"))
        col.addArrangedSubview(qualitySection())
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
        let title = UI.label("画质设置", size: 13, weight: .semibold)
        let note = UI.label("作为显示器时生效", size: 11, color: Theme.sub)
        let hrow = UI.hstack([chev, title, note, NSView()], spacing: 8)
        embed(hrow, in: head, padX: 12, padY: 10)
        let click = ClickCatcher { [weak self] in self?.qualityOpen.toggle(); self?.rebuild() }
        head.addSubview(click); click.translatesAutoresizingMaskIntoConstraints = false; pin(click, to: head)

        let col = UI.vstack([head], spacing: 0)
        if qualityOpen {
            let opts = UI.vstack([
                qualityGroup("分辨率", ["跟随对方", "1920×1080", "2560×1440"]),
                qualityGroup("缩放", ["100%", "150%", "200%"]),
                qualityGroup("帧率", ["30 fps", "60 fps"]),
                qualityGroup("码率", ["自动", "10 Mbps", "20 Mbps"]),
            ], spacing: 12)
            let pad = wrapPadded(opts, x: 12, y: 12, topLine: true)
            col.addArrangedSubview(pad)
        }
        embed(col, in: box, pad: 0)
        return fullWidthView(box)
    }

    private func qualityGroup(_ label: String, _ options: [String]) -> NSView {
        let lbl = UI.label(label, size: 12, color: Theme.sub)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: 52).isActive = true
        var chips: [NSView] = []
        for o in options {
            let sel = o == options.first   // placeholder selection until wired to config
            let c = UI.button(o, fill: sel ? Theme.recvWeak : .clear, textColor: sel ? Theme.recv : Theme.sub,
                              border: sel ? Theme.recv : Theme.line, radius: 6, size: 12, weight: .regular,
                              target: self, action: #selector(noop))
            c.translatesAutoresizingMaskIntoConstraints = false
            c.heightAnchor.constraint(equalToConstant: 24).isActive = true
            chips.append(c)
        }
        let chipRow = UI.hstack(chips, spacing: 6)
        return UI.hstack([lbl, chipRow], spacing: 10, align: .centerY)
    }

    // MARK: - Paired devices

    private func devicesSection() -> NSView {
        let header = UI.hstack([
            UI.label("已配对设备", size: 12, weight: .semibold, color: Theme.sub),
            NSView(),
            UI.button("＋ 添加设备", fill: .clear, textColor: Theme.accent, radius: 6, size: 12,
                      weight: .regular, target: self, action: #selector(tapAddDevice)),
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
        let online = UI.dot(d.isPending ? Theme.sub : Theme.accent, size: 8)
        let name = UI.label(d.displayName, size: 13)
        let status = UI.label(d.isPending ? "待配对完成" : model.connLabel, size: 11, color: Theme.sub)
        let inner = UI.hstack([radio, online, name, NSView(), status], spacing: 9)
        embed(inner, in: row, padX: 10, padY: 8)
        let click = ClickCatcher { [weak self] in self?.model.select(secret: d.secret) }
        row.addSubview(click); click.translatesAutoresizingMaskIntoConstraints = false; pin(click, to: row)
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

    @objc private func tapCastTab() { onCastTab = true; rebuild() }
    @objc private func tapRecvTab() { onCastTab = false; rebuild() }
    @objc private func tapStartCast() {
        guard model.startCasting() else { return }
        // UI drives the 0.9s switching settle (design).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.model.finishSwitchToCasting() }
    }
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
    @objc private func noop() {}

    func windowWillClose(_ notification: Notification) {}
}

/// Top-down coordinate view for the panel body.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A transparent overlay that runs a closure on click (for row selection).
final class ClickCatcher: NSView {
    private let onClick: () -> Void
    init(_ onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick() }
}

private extension NSWindow {
    /// Small no-op hook kept for readability where window chrome is tuned.
    func titidy() { self.isMovableByWindowBackground = true }
}
