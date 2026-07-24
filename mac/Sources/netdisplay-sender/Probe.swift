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
            guard let c else { return }
            parser.feed(data)
            if let frame = try? parser.next(), let t = MsgType(rawValue: frame.type) {
                if t == .probe { c.send(Wire.encode(.probeAck, frame.payload)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self?.drop(id, c) }
            }
        }
        c.onClose = { [weak self] in self?.drop(id, c) }
        c.start { _ in }
    }

    private func drop(_ id: ObjectIdentifier, _ c: Conn) {
        c.close()
        lock.lock(); conns[id] = nil; lock.unlock()
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
