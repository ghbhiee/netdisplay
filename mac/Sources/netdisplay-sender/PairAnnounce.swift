import Foundation
import Network

/// Mutual pairing client (docs/11 / protocol §2, v1.12). Announces "I'm pairing
/// on this room" to the relay and waits for the peer to announce the same room —
/// the relay then sends PAIR_CONFIRMED with the peer's deviceId+name. Keeps
/// waiting (re-announcing on the relay's TTL) until confirmed, failed, or
/// cancelled. This is what makes "已配对" honest: it only fires once the *other*
/// machine really used the same code.
final class PairAnnounce {
    enum Result: Equatable {
        case confirmed(peerDeviceId: String, peerName: String)
        case failed(reason: String)   // token bad / unreachable
    }

    private let host: String
    private let port: UInt16
    private let pairHash: String
    private let deviceId: String
    private let name: String
    private let token: String?
    private let onResult: (Result) -> Void

    private var conn: Conn?
    private var parser = FrameParser()
    private var cancelled = false
    private var settled = false
    private var selfRef: PairAnnounce?

    private init(host: String, port: UInt16, pairHash: String, deviceId: String, name: String,
                 token: String?, onResult: @escaping (Result) -> Void) {
        self.host = host; self.port = port; self.pairHash = pairHash
        self.deviceId = deviceId; self.name = name; self.token = token; self.onResult = onResult
    }

    /// Begin announcing. `onResult` is called once on the main queue. Returns a
    /// handle whose `cancel()` stops waiting.
    @discardableResult
    static func start(server: String, token: String?, pairHash: String, deviceId: String,
                      name: String, onResult: @escaping (Result) -> Void) -> PairAnnounce {
        let parts = server.split(separator: ":")
        let host = String(parts.first ?? "15.tokencv.com")
        let port = UInt16(parts.count > 1 ? Int(parts[1]) ?? Int(Proto.relayPort) : Int(Proto.relayPort))
        let pa = PairAnnounce(host: host, port: port, pairHash: pairHash, deviceId: deviceId,
                              name: name, token: token) { r in DispatchQueue.main.async { onResult(r) } }
        pa.selfRef = pa
        pa.connect()
        return pa
    }

    func cancel() {
        cancelled = true
        conn?.close(); conn = nil
        selfRef = nil
    }

    private func connect() {
        if cancelled || settled { return }
        parser = FrameParser()
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let c = Conn(NWConnection(to: ep, using: Conn.tcpParameters()), label: "pair-announce")
        conn = c
        c.onData = { [weak self] d in self?.onData(d) }
        c.onClose = { [weak self] in self?.onClose() }
        c.start { [weak self] st in
            guard let self, case .ready = st else { return }
            let ann = PairAnnounce.encoded(self)
            c.send(ann)
        }
    }

    private static func encoded(_ s: PairAnnounce) -> Data {
        Wire.encodeJSON(.pairAnnounce, PairAnnounce.Payload(
            v: 1, pairHash: s.pairHash, deviceId: s.deviceId, name: s.name, token: s.token))
    }
    private struct Payload: Codable { let v: Int; let pairHash: String; let deviceId: String; let name: String; let token: String? }

    private func onData(_ data: Data) {
        parser.feed(data)
        while let frame = try? parser.next() {
            guard let t = MsgType(rawValue: frame.type) else { continue }
            switch t {
            case .pairConfirmed:
                if let c = try? JSONDecoder().decode(PairConfirmed.self, from: frame.payload) {
                    finish(.confirmed(peerDeviceId: c.peerDeviceId, peerName: c.peerName))
                }
            case .relayError:
                let reason = (try? JSONDecoder().decode(RelayError.self, from: frame.payload))?.reason ?? "?"
                finish(.failed(reason: reason))
            default: break
            }
        }
    }

    /// Relay closed us (TTL, or peer gone). If we haven't settled and aren't
    /// cancelled, re-announce so the user keeps waiting for the peer.
    private func onClose() {
        if settled || cancelled { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.connect() }
    }

    private func finish(_ r: Result) {
        if settled { return }
        settled = true
        conn?.close(); conn = nil
        onResult(r)
        selfRef = nil
    }
}
