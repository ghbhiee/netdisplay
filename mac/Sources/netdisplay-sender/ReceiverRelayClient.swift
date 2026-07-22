import Foundation
import Network
import CoreMedia
import CoreVideo

/// Relay mode for the Receiver (mirror of RelayClient). Dials the relay and sends
/// RELAY_JOIN with the Sender's 6-digit code (or a stored pairHash for code-free
/// reconnect). On RELAY_PAIRED the pipe is transparent, so it hands off to a
/// ReceiverSession which runs the normal Receiver handshake + decode.
final class ReceiverRelayClient {
    private let host: String
    private let port: UInt16
    private let token: String?
    private let code: String?
    private let name: String
    private let deviceId: String
    private let screen: HelloReceiver.Screen
    private let codecs: [String]

    private var conn: Conn?
    private var relayParser = FrameParser()
    private var paired = false
    private var session: ReceiverSession?
    private var backoff: Double = 1
    private var reconnectWork: DispatchWorkItem?
    private var stopped = false

    /// Frames sink forwarded to the active ReceiverSession (renderer hook later).
    var onFrame: ((_ image: CVImageBuffer, _ pts: CMTime) -> Void)?
    /// Forwarded once the inner session's handshake is accepted.
    var onReady: ((_ display: HelloAck.Display?, _ codec: VideoCodec) -> Void)?
    /// Applied to the inner ReceiverSession (RECV_STATS export).
    var statsEmitSec: Int?
    var statsRepeat = true

    init(host: String, port: UInt16, token: String?, code: String?,
         name: String, deviceId: String, screen: HelloReceiver.Screen, codecs: [String]) {
        self.host = host
        self.port = port
        self.token = token
        self.code = code
        self.name = name
        self.deviceId = deviceId
        self.screen = screen
        self.codecs = codecs
    }

    func start() { connect() }

    private func connect() {
        paired = false
        relayParser = FrameParser()
        session = nil

        let pairHash = PairStore.currentPairHash(slot: "receiver")
        if pairHash == nil && (code == nil || code!.isEmpty) {
            Log.error("relay-receive: no pairing code and no stored pairing — pass --code <6-digit>")
            exit(2)
        }
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let nw = NWConnection(to: ep, using: Conn.tcpParameters())
        let c = Conn(nw, label: "netdisplay.relay-recv")
        conn = c
        c.onData = { [weak self] in self?.onRelayData($0) }
        c.onClose = { [weak self] in self?.onRelayClose() }
        c.start { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                let join = RelayJoin(v: 1, role: "receiver", code: self.code ?? "",
                                     pairHash: pairHash, token: self.token)
                c.send(Wire.encodeJSON(.relayJoin, join))
                self.backoff = 1
                if pairHash != nil {
                    Log.info("relay-receive: JOIN with pairHash (code-free), waiting to pair")
                } else {
                    Log.info("relay-receive: JOIN with code \(self.code ?? "?"), waiting to pair")
                }
            }
        }
    }

    private func onRelayData(_ data: Data) {
        if paired { session?.attach(conn: conn!, leftover: data); return } // shouldn't reach
        relayParser.feed(data)
        do {
            while let frame = try relayParser.next() {
                handleControl(frame)
                if paired { break }
            }
        } catch {
            Log.error("relay-receive: parse error \(error)"); conn?.close()
        }
    }

    private func handleControl(_ frame: FrameParser.Frame) {
        guard let type = MsgType(rawValue: frame.type) else { return }
        switch type {
        case .relayPaired:
            Log.info("relay-receive: PAIRED — handing off to receiver session")
            paired = true
            guard let conn else { return }
            let leftover = relayParser.drainRemaining()
            let rs = ReceiverSession(host: host, port: port, name: name, deviceId: deviceId,
                                     screen: screen, codecs: codecs)
            rs.onFrame = { [weak self] img, pts in self?.onFrame?(img, pts) }
            rs.onReady = { [weak self] display, codec in self?.onReady?(display, codec) }
            rs.onClosed = { [weak self] in self?.onSessionClosed() }
            rs.statsEmitSec = statsEmitSec
            rs.statsRepeat = statsRepeat
            session = rs
            rs.attach(conn: conn, leftover: leftover)
        case .relayError:
            let reason = (try? JSONDecoder().decode(RelayError.self, from: frame.payload))?.reason ?? "?"
            Log.error("relay-receive: RELAY_ERROR \(reason)"); conn?.close()
        default:
            break
        }
    }

    private func onSessionClosed() {
        // Code-free reconnect only makes sense once we have a stored pairing.
        if PairStore.currentPairHash(slot: "receiver") != nil { scheduleReconnect() }
        else { stop(); exit(0) }
    }

    private func onRelayClose() {
        if paired { return } // session close handles the decision
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        if stopped { return }
        reconnectWork?.cancel()
        let delay = backoff
        backoff = min(30, backoff * 2)
        Log.info("relay-receive: reconnecting in \(delay)s")
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stop() {
        stopped = true
        reconnectWork?.cancel(); reconnectWork = nil
        session?.close()
        conn?.close(); conn = nil
    }
}
