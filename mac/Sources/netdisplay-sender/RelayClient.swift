import Foundation
import Network
import Security

/// Relay mode (protocol §3.2 / §7): dial the relay, RELAY_REGISTER with a fresh
/// 6-digit pairing code, and on RELAY_PAIRED hand the (now transparent) pipe to
/// a Session. Reconnects with exponential backoff, generating a new code each time.
final class RelayClient {
    private let host: String
    private let port: UInt16
    private let bitrateBps: Int
    private let senderName: String
    private let deviceId: String
    private let token: String?
    private let override: DisplayOverride
    private let prioritizeQuality: Bool
    private let windowApp: String?
    private let bitrateExplicit: Bool
    private let stage: Bool
    /// Explicit pairHash (shared --secret/--pairhash) pinning the relay room for
    /// CLI-only tests; overrides the stored sender pairing.
    var pairHashOverride: String?

    private var conn: Conn?
    private var relayParser = FrameParser()
    private var paired = false
    private var session: Session?
    private var backoff: Double = 1
    private var reconnectWork: DispatchWorkItem?
    private var stopped = false

    var onState: ((SenderState) -> Void)?
    var currentSession: Session? { session }

    init(host: String, port: UInt16, bitrateBps: Int, senderName: String, deviceId: String,
         token: String? = nil, override: DisplayOverride = DisplayOverride(), prioritizeQuality: Bool = false,
         windowApp: String? = nil, bitrateExplicit: Bool = true, stage: Bool = false) {
        self.host = host
        self.port = port
        self.bitrateBps = bitrateBps
        self.senderName = senderName
        self.deviceId = deviceId
        self.token = token
        self.override = override
        self.prioritizeQuality = prioritizeQuality
        self.windowApp = windowApp
        self.bitrateExplicit = bitrateExplicit
        self.stage = stage
    }

    func start() {
        connect()
    }

    private func connect() {
        paired = false
        relayParser = FrameParser()
        session = nil

        let code = Self.generateCode()
        let pairHash = pairHashOverride ?? PairStore.currentPairHash()   // non-nil → auto-match, no code
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: port)!)
        let nw = NWConnection(to: endpoint, using: Conn.tcpParameters())
        let conn = Conn(nw, label: "netdisplay.relay")
        self.conn = conn

        conn.onData = { [weak self] data in self?.onRelayData(data) }
        conn.onClose = { [weak self] in self?.onRelayClose() }
        conn.start { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                Log.info("relay: connected to \(self.host):\(self.port)")
                let reg = RelayRegister(v: 1, role: "sender", code: code, pairHash: pairHash, token: self.token)
                conn.send(Wire.encodeJSON(.relayRegister, reg))
                self.backoff = 1
                if pairHash != nil {
                    // Persistent pairing: peer auto-matches by pairHash, no code entry.
                    print("\n  ✓ 已持久配对，自动待命（无需配对码）\n")
                    Log.info("relay: registered with pairHash (persistent pairing), waiting for peer")
                    self.onState?(.waitingForPeer(code: "已配对·免码"))
                } else {
                    print("")
                    print("  ┌───────────────────────────────────┐")
                    print("  │  NetDisplay 配对码 (pairing code)   │")
                    print("  │            \(code)                 │")
                    print("  │  在 Windows 端输入此码即可连接        │")
                    print("  └───────────────────────────────────┘")
                    print("")
                    Log.info("relay: registered with code \(code), waiting for peer")
                    self.onState?(.waitingForPeer(code: code))
                }
            }
        }
    }

    private func onRelayData(_ data: Data) {
        if paired {
            // Should not happen (onData reassigned to session), but forward defensively.
            session?.feedRaw(data)
            return
        }
        relayParser.feed(data)
        do {
            while let frame = try relayParser.next() {
                handleControl(frame)
                if paired { break }
            }
        } catch {
            Log.error("relay: parse error \(error)")
            conn?.close()
        }
    }

    private func handleControl(_ frame: FrameParser.Frame) {
        guard let type = MsgType(rawValue: frame.type) else { return }
        switch type {
        case .relayPaired:
            Log.info("relay: PAIRED — handing off to session")
            paired = true
            guard let conn else { return }
            let leftover = relayParser.drainRemaining()
            let session = Session(conn: conn, bitrateBps: bitrateBps,
                                  senderName: senderName, deviceId: deviceId,
                                  override: override, prioritizeQuality: prioritizeQuality,
                                  windowApp: windowApp, bitrateExplicit: bitrateExplicit, stage: stage)
            session.onStreaming = { [weak self] w, h, fps, scale in
                self?.onState?(.streaming(w: w, h: h, fps: fps, scale: scale))
            }
            session.onEnd = { [weak self] in self?.scheduleReconnect() }
            self.session = session
            session.begin() // reassigns conn.onData → session.ingest, sends HELLO
            session.feedRaw(leftover)
        case .relayError:
            let reason = (try? JSONDecoder().decode(RelayError.self, from: frame.payload))?.reason ?? "?"
            Log.error("relay: RELAY_ERROR \(reason)")
            conn?.close()
        default:
            break
        }
    }

    private func onRelayClose() {
        if paired { return } // session.onEnd handles reconnect
        scheduleReconnect()
    }

    func stop() {
        stopped = true
        reconnectWork?.cancel(); reconnectWork = nil
        session?.end(reason: "stopped by user")
        session = nil
        conn?.close(); conn = nil
    }

    private func scheduleReconnect() {
        if stopped { return }
        onState?(.connecting)
        reconnectWork?.cancel()
        let delay = backoff
        backoff = min(30, backoff * 2)
        Log.info("relay: reconnecting in \(delay)s")
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Cryptographically random 6-digit code in [100000, 999999].
    static func generateCode() -> String {
        var raw: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &raw) { buf in
            SecRandomCopyBytes(kSecRandomDefault, 4, buf.baseAddress!)
        }
        if status != errSecSuccess {
            raw = UInt32(truncatingIfNeeded: UInt(bitPattern: ObjectIdentifier(NSObject()).hashValue))
        }
        return String(100000 + (raw % 900000))
    }
}
