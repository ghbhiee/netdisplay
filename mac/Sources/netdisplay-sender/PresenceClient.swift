import Foundation
import Network

/// Presence client (docs/11 §5 / protocol §2, v1.14). Keeps a connection to the
/// relay for one paired device, reports this machine's state, and receives the
/// peer's live state (so the device row can show 「对方待接收 · 可投射」etc).
/// Reconnects on drop; call `update(state:)` when the local role changes.
final class PresenceClient {
    private let host: String
    private let port: UInt16
    private let pairHash: String
    private let deviceId: String
    private let name: String
    private let token: String?
    private var conn: Conn?
    private var parser = FrameParser()
    private var state: String
    private var stopped = false
    private var backoff: Double = 1

    /// Called (main queue) with the peer's state, or "offline".
    var onPeer: ((String) -> Void)?

    init(server: String, token: String?, pairHash: String, deviceId: String, name: String, state: String) {
        let parts = server.split(separator: ":")
        self.host = String(parts.first ?? "15.tokencv.com")
        self.port = UInt16(parts.count > 1 ? Int(parts[1]) ?? Int(Proto.relayPort) : Int(Proto.relayPort))
        self.token = token; self.pairHash = pairHash; self.deviceId = deviceId; self.name = name; self.state = state
    }

    func start() { connect() }

    func update(state newState: String) {
        state = newState
        sendPresence()
    }

    func stop() {
        stopped = true
        conn?.close(); conn = nil
    }

    private struct Payload: Codable { let v: Int; let pairHash: String; let deviceId: String; let name: String; let state: String; let token: String? }

    private func sendPresence() {
        conn?.send(Wire.encodeJSON(.presence, Payload(
            v: 1, pairHash: pairHash, deviceId: deviceId, name: name, state: state, token: token)))
    }

    private func connect() {
        if stopped { return }
        parser = FrameParser()
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let c = Conn(NWConnection(to: ep, using: Conn.tcpParameters()), label: "presence")
        conn = c
        c.onData = { [weak self] d in self?.onData(d) }
        c.onClose = { [weak self] in self?.onClose() }
        c.start { [weak self] st in
            guard let self, case .ready = st else { return }
            self.backoff = 1
            self.sendPresence()
        }
    }

    private func onData(_ data: Data) {
        parser.feed(data)
        while let frame = try? parser.next() {
            if MsgType(rawValue: frame.type) == .peerPresence,
               let pp = try? JSONDecoder().decode(PeerPresence.self, from: frame.payload) {
                let s = pp.peerState
                DispatchQueue.main.async { [weak self] in self?.onPeer?(s) }
            }
        }
    }

    private func onClose() {
        if stopped { return }
        let delay = backoff; backoff = min(30, backoff * 2)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }
}

struct PeerPresence: Codable {
    let peerDeviceId: String
    let peerName: String
    let peerState: String
}
