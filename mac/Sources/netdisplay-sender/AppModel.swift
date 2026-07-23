import Foundation

/// Presentation state machine for the redesigned UI (docs/design README
/// 「Interactions & Behavior」). Both the main panel and the tray menu render
/// from this; it owns *what state we're in*, not the transport. Side effects
/// (start/stop the real sender/receiver) are delivered through the `on*` hooks so
/// this stays pure and testable.
final class AppModel {
    enum Role: String { case standby, switching, casting, receiving }
    enum RecvSvc: String { case off, waiting }
    enum Conn: String { case off, connecting, on }

    /// Projection source memory (design: pickSel, persisted, shared panel/menu).
    enum Source: Equatable {
        case screen
        case window(String)
        var isScreen: Bool { if case .screen = self { return true }; return false }
    }

    private(set) var role: Role = .standby
    private(set) var recvSvc: RecvSvc = .off
    private(set) var conn: Conn = .off
    private(set) var source: Source = .screen

    var devices: [PairedDevice] = []
    var selectedSecret: String?
    var selected: PairedDevice? { devices.first { $0.secret == selectedSecret } }

    /// Fires after any state change so observers rebuild UI.
    var onChange: (() -> Void)?
    /// Side-effect hooks (wired to SenderController / receiver by the app layer).
    var onStartCasting: ((PairedDevice, Source) -> Void)?
    var onStopCasting: (() -> Void)?
    var onStartRecvService: (() -> Void)?
    var onStopRecvService: (() -> Void)?

    init() {
        devices = DeviceStore.load()
        selectedSecret = devices.first { $0.deviceId == DeviceStore.selectedId }?.secret ?? devices.first?.secret
        source = Self.loadSource()
    }

    private func changed() { onChange?() }

    // MARK: - Source (persisted)

    private static let sourceKey = "netdisplay.pickSel"
    private static func loadSource() -> Source {
        guard let s = UserDefaults.standard.string(forKey: sourceKey), !s.isEmpty else { return .screen }
        return s == "@screen" ? .screen : .window(s)
    }
    func setSource(_ s: Source) {
        source = s
        UserDefaults.standard.set(s.isScreen ? "@screen" : { if case .window(let a) = s { return a }; return "@screen" }(), forKey: Self.sourceKey)
        // A live source change while casting switches without a reconnect (VIDEO_CONFIG).
        if role == .casting, let d = selected { onStartCasting?(d, s) }
        changed()
    }

    // MARK: - Selection

    func select(secret: String?) {
        selectedSecret = secret
        DeviceStore.selectedId = devices.first { $0.secret == secret }?.deviceId
        changed()
    }

    // MARK: - Casting (投射本机)

    /// Can we begin casting? (design 禁用条件: 未选设备 / 正在接收 / 接收服务开着的互斥。)
    var canCast: Bool { role == .standby && selected != nil && recvSvc == .off }

    /// Begin casting to the selected device (design: 开始投射 implicitly connects).
    /// Returns false (with no state change) if blocked.
    @discardableResult
    func startCasting() -> Bool {
        guard role == .standby, selected != nil else { return false }
        guard recvSvc != .waiting else { return false }   // mutex: receiving service on → can't cast
        role = .switching
        conn = .connecting
        changed()
        return true
    }
    /// Called when the switching/connecting settle timer fires (UI drives the 0.9s).
    func finishSwitchToCasting() {
        guard role == .switching, let d = selected else { return }
        role = .casting; conn = .on
        onStartCasting?(d, source)
        changed()
    }
    func stopCasting() {
        guard role == .casting || (role == .switching) else { return }
        role = .standby; conn = .off
        onStopCasting?()
        changed()
    }

    // MARK: - Receiving (接收显示)

    func startRecvService() {
        guard role != .casting else { return }   // mutex
        recvSvc = .waiting
        onStartRecvService?()
        changed()
    }
    func stopRecvService() {
        recvSvc = .off
        if role == .receiving { role = .standby; conn = .off }
        onStopRecvService?()
        changed()
    }
    /// Peer started projecting to us — auto-enter receiving (design: standby +
    /// waiting + incoming → switching → receiving).
    func receiveStarted() {
        guard recvSvc == .waiting, role != .casting else { return }
        role = .receiving; conn = .on
        changed()
    }
    /// Disconnect the incoming projection but keep the service waiting.
    func receiveStopped() {
        if role == .receiving { role = .standby; conn = .off }
        changed()
    }

    /// Losing the selected device's connection forces standby (design rule).
    func connectionDropped() {
        if role == .casting || role == .receiving || role == .switching {
            role = .standby; conn = .off
        }
        changed()
    }

    // MARK: - Human-readable status (design wording)

    var connLabel: String { conn == .on ? "已连接" : conn == .connecting ? "连接中…" : "未连接" }
}
