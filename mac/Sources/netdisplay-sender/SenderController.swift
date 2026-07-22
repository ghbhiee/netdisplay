import Foundation

/// High-level sender state for the menu-bar UI.
enum SenderState {
    case stopped
    case listening(port: Int)           // direct mode, waiting for a receiver
    case connecting                     // relay: dialing / reconnecting
    case waitingForPeer(code: String)   // relay: registered, waiting for a join
    case streaming(w: Int, h: Int, fps: Int, scale: Int)
    case error(String)

    var short: String {
        switch self {
        case .stopped: return "已停止"
        case .listening(let p): return "直连待接入 :\(p)"
        case .connecting: return "连接中…"
        case .waitingForPeer(let c): return "配对码 \(c)"
        case .streaming(let w, let h, let fps, let s):
            return "投送中 \(w)×\(h)@\(fps)" + (s >= 2 ? " @\(s)x" : "")
        case .error(let e): return "错误：\(e)"
        }
    }
}

/// User-adjustable configuration, persisted to UserDefaults.
struct AppConfig: Codable, Equatable {
    enum Mode: String, Codable { case relay, direct }

    var mode: Mode = .relay
    var relayServer = "15.tokencv.com:47700"
    var listenPort = 47800
    // nil width/height = adopt the receiver's reported resolution.
    var width: Int? = nil
    var height: Int? = nil
    var scale = 2          // default HiDPI so text isn't tiny on high-density panels
    var fps = 60
    var bitrateMbps = 20
    var bitrateAuto = false   // true → adopt the Receiver's requested bitrate (HELLO.screen.bitrateMbps)
    var quality = true
    var windowApp: String? = nil   // non-nil → project this app's window instead of the desktop
    var stage = false              // window mode: move the window onto an off-main stage display

    var override: DisplayOverride {
        DisplayOverride(width: width, height: height, scale: scale, fps: fps)
    }

    private static let key = "netdisplay.appconfig"
    static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return cfg
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Owns the running sender (relay or direct) and restarts it when the config
/// changes, so menu edits take effect live.
final class SenderController {
    private(set) var config: AppConfig
    private let senderName: String
    private let deviceId: String

    private var relay: RelayClient?
    private var server: SessionServer?

    var onState: ((SenderState) -> Void)?
    private(set) var state: SenderState = .stopped {
        didSet { onState?(state) }
    }
    private(set) var running = false

    init(senderName: String, deviceId: String, config: AppConfig = .load()) {
        self.senderName = senderName
        self.deviceId = deviceId
        self.config = config
    }

    func start() {
        guard !running else { return }
        running = true
        let bitrate = config.bitrateMbps * 1_000_000
        switch config.mode {
        case .relay:
            let parts = config.relayServer.split(separator: ":")
            let host = String(parts.first ?? "15.tokencv.com")
            let port = UInt16(parts.count > 1 ? Int(parts[1]) ?? 47700 : 47700)
            let r = RelayClient(host: host, port: port, bitrateBps: bitrate,
                                senderName: senderName, deviceId: deviceId,
                                override: config.override, prioritizeQuality: config.quality,
                                windowApp: config.windowApp, bitrateExplicit: !config.bitrateAuto,
                                stage: config.stage)
            r.onState = { [weak self] st in self?.state = st }
            relay = r
            state = .connecting
            r.start()
        case .direct:
            let s = SessionServer(port: UInt16(config.listenPort), bitrateBps: bitrate,
                                  senderName: senderName, deviceId: deviceId,
                                  override: config.override, prioritizeQuality: config.quality,
                                  windowApp: config.windowApp, bitrateExplicit: !config.bitrateAuto,
                                  stage: config.stage)
            s.onState = { [weak self] st in self?.state = st }
            server = s
            do { try s.start(); state = .listening(port: config.listenPort) }
            catch { state = .error("\(error.localizedDescription)"); running = false }
        }
    }

    func stop() {
        relay?.stop(); relay = nil
        server?.stop(); server = nil
        running = false
        state = .stopped
    }

    private var activeSession: Session? { relay?.currentSession ?? server?.currentSession }

    /// Apply a new config. Connection-level changes (mode/server/bitrate/quality)
    /// reconnect; projection-level changes (source/resolution/scale/fps) switch
    /// live over the existing connection — no reconnect, target app stays up.
    func update(_ newConfig: AppConfig) {
        let old = config
        config = newConfig
        config.save()
        guard running else { return }

        let connLevel = old.mode != newConfig.mode
            || old.relayServer != newConfig.relayServer
            || old.listenPort != newConfig.listenPort
            || old.bitrateMbps != newConfig.bitrateMbps
            || old.bitrateAuto != newConfig.bitrateAuto
            || old.quality != newConfig.quality
        if connLevel {
            stop(); start(); return
        }
        // Projection-only change → live switch if a session is up, else restart.
        if let sess = activeSession {
            sess.switchSource(to: ProjectionSource(
                windowApp: newConfig.windowApp, stage: newConfig.stage,
                override: newConfig.override, prioritizeQuality: newConfig.quality))
            Log.info("controller: live source switch (no reconnect)")
        } else {
            stop(); start()
        }
    }
}
