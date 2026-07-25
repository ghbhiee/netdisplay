import Foundation
import Network

/// Always-on responder on :47800 — answers a `PROBE` with `PROBE_ACK` (echoing
/// the 8 bytes) so a peer can verify **direct** connectivity (docs/11 §2 /
/// protocol §3.8). App-layer reply, so it can't be faked by Clash TUN. Coexists
/// with the direct projection session: a first frame that's HELLO would belong to
/// a session (not handled here yet, so closed); PROBE gets an ACK.
final class ProbeResponder {
    private var listener: NWListener?
    private let port: UInt16
    private var conns: [ObjectIdentifier: Conn] = [:]
    private let lock = NSLock()
    /// Our identity, to reply to a direct PAIR_HELLO (§6).
    var myDeviceId = ""
    var myName = ""
    /// Called when a peer completes a direct (IP) pairing with us: (peerDeviceId,
    /// peerName, peerAddr, sharedSecret). The app saves the device.
    var onPairRequest: ((String, String, String, String) -> Void)?

    init(port: UInt16 = UInt16(Proto.directPort)) { self.port = port }

    func start() {
        do {
            let l = try NWListener(using: Conn.tcpParameters(), on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] nw in self?.handle(nw) }
            l.start(queue: .global())
            listener = l
            Log.info("probe-responder: listening on :\(port)")
        } catch {
            Log.error("probe-responder: bind :\(port) failed — \(error)")
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ nw: NWConnection) {
        let c = Conn(nw, label: "probe-resp")
        let id = ObjectIdentifier(c)
        lock.lock(); conns[id] = c; lock.unlock()
        let parser = FrameParser()
        c.onData = { [weak self, weak c] data in
            guard let self, let c else { return }
            parser.feed(data)
            guard let frame = try? parser.next(), let t = MsgType(rawValue: frame.type) else { return }
            switch t {
            case .probe:
                c.send(Wire.encode(.probeAck, frame.payload))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self.drop(id, c) }
            case .pairHello:
                // Direct (IP) pairing: save the peer, reply with our identity (§6).
                if let ph = try? JSONDecoder().decode(PairHello.self, from: frame.payload) {
                    let addr = ProbeResponder.remoteHost(nw)
                    self.onPairRequest?(ph.deviceId, ph.name, addr, ph.secret ?? "")
                    c.send(Wire.encodeJSON(.pairHello, PairHello(v: 1, deviceId: self.myDeviceId, name: self.myName, secret: nil)))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self.drop(id, c) }
            default:
                self.drop(id, c)   // HELLO (projection session) not handled here yet
            }
        }
        c.onClose = { [weak self] in self?.drop(id, c) }
        c.start { _ in }
    }

    private func drop(_ id: ObjectIdentifier, _ c: Conn) {
        c.close()
        lock.lock(); conns[id] = nil; lock.unlock()
    }

    /// Peer IP of an inbound connection (for storing a direct-pair device's addr).
    static func remoteHost(_ nw: NWConnection) -> String {
        if case .hostPort(let host, _)? = nw.currentPath?.remoteEndpoint {
            return "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        }
        if case .hostPort(let host, _) = nw.endpoint {
            return "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        }
        return ""
    }
}

/// Direct (IP) pairing initiator (docs/11 §6). Dials a peer's :47800, sends a
/// PAIR_HELLO with our identity + a generated secret (relay-room fallback), and
/// waits for the peer's PAIR_HELLO reply. No relay involved.
final class DirectPair {
    enum Result: Equatable { case paired(peerDeviceId: String, peerName: String), fail(String) }

    private let completion: (Result) -> Void
    private var conn: Conn?
    private var parser = FrameParser()
    private let deviceId: String
    private let name: String
    private let secret: String
    private var done = false
    private var selfRef: DirectPair?

    private init(deviceId: String, name: String, secret: String, completion: @escaping (Result) -> Void) {
        self.deviceId = deviceId; self.name = name; self.secret = secret; self.completion = completion
    }

    static func pair(host: String, port: UInt16 = UInt16(Proto.directPort),
                     deviceId: String, name: String, secret: String,
                     completion: @escaping (Result) -> Void) {
        let p = DirectPair(deviceId: deviceId, name: name, secret: secret) { r in
            DispatchQueue.main.async { completion(r) }
        }
        p.selfRef = p
        p.run(host: host, port: port)
    }

    private func run(host: String, port: UInt16) {
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let c = Conn(NWConnection(to: ep, using: Conn.tcpParameters()), label: "direct-pair")
        conn = c
        c.onData = { [weak self] d in self?.onData(d) }
        c.onClose = { [weak self] in self?.finish(.fail("对方无响应")) }
        c.start { [weak self] st in
            guard let self, case .ready = st else { return }
            c.send(Wire.encodeJSON(.pairHello, PairHello(v: 1, deviceId: self.deviceId, name: self.name, secret: self.secret)))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.finish(.fail("直连超时（对方 IP 不通或未开程序）")) }
    }

    private func onData(_ data: Data) {
        parser.feed(data)
        while let frame = try? parser.next() {
            if MsgType(rawValue: frame.type) == .pairHello,
               let ph = try? JSONDecoder().decode(PairHello.self, from: frame.payload) {
                finish(.paired(peerDeviceId: ph.deviceId, peerName: ph.name))
            }
        }
    }

    private func finish(_ r: Result) {
        if done { return }
        done = true
        conn?.close(); conn = nil
        completion(r)
        selfRef = nil
    }
}

/// Dials a peer's :47800 and verifies direct connectivity by a PROBE→PROBE_ACK
/// round-trip. **Success = matching PROBE_ACK received, never bare TCP connect**
/// (TUN fakes connect). Reports RTT in ms or failure (≤1.5s).
final class DirectProbe {
    enum Result: Equatable { case ok(ms: Int), fail }

    private let completion: (Result) -> Void
    private var conn: Conn?
    private var parser = FrameParser()
    private let sent: Data
    private let started = DispatchTime.now()
    private var done = false
    private var selfRef: DirectProbe?

    private init(completion: @escaping (Result) -> Void) {
        self.completion = completion
        self.sent = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
    }

    static func probe(host: String, port: UInt16 = UInt16(Proto.directPort),
                      completion: @escaping (Result) -> Void) {
        let p = DirectProbe { r in DispatchQueue.main.async { completion(r) } }
        p.selfRef = p
        p.run(host: host, port: port)
    }

    private func run(host: String, port: UInt16) {
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let c = Conn(NWConnection(to: ep, using: Conn.tcpParameters()), label: "direct-probe")
        conn = c
        c.onData = { [weak self] d in self?.onData(d) }
        c.onClose = { [weak self] in self?.finish(.fail) }
        c.start { [weak self] st in
            guard let self, case .ready = st else { return }
            c.send(Wire.encode(.probe, self.sent))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish(.fail) }
    }

    private func onData(_ data: Data) {
        parser.feed(data)
        while let frame = try? parser.next() {
            if MsgType(rawValue: frame.type) == .probeAck && frame.payload == sent {
                let ms = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
                finish(.ok(ms: ms))
            }
        }
    }

    private func finish(_ r: Result) {
        if done { return }
        done = true
        conn?.close(); conn = nil
        completion(r)
        selfRef = nil
    }
}
