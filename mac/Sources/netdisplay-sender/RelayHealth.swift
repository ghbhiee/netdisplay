import Foundation
import Network

/// Checks whether the relay is actually reachable and the token is accepted —
/// robustly under Clash TUN, where a bare TCP `connect` succeeds even to a black
/// hole. The trick: open two connections, REGISTER a random room on one and JOIN
/// it on the other; only a *real* relay returns RELAY_PAIRED. A wrong token makes
/// REGISTER come back RELAY_ERROR "unauthorized". Neither positive signal can be
/// faked by a proxy swallowing the connection.
final class RelayHealth {
    enum Status: Equatable {
        case unknown, checking, ok(ms: Int), unauthorized, unreachable
    }

    private var a: Conn?
    private var b: Conn?
    private var pa = FrameParser()
    private var pb = FrameParser()
    private let lock = NSLock()
    private var finished = false
    private var selfRef: RelayHealth?   // keep the probe alive during the async check
    private let completion: (Status) -> Void
    private let started = DispatchTime.now()

    private init(completion: @escaping (Status) -> Void) { self.completion = completion }

    /// Run a one-shot check. `completion` is called exactly once on the main queue.
    static func check(server: String, token: String?, completion: @escaping (Status) -> Void) {
        let h = RelayHealth { st in DispatchQueue.main.async { completion(st) } }
        h.run(server: server, token: token)
    }

    private func run(server: String, token: String?) {
        selfRef = self   // stay alive until finish()
        let parts = server.split(separator: ":")
        let host = String(parts.first ?? "")
        let port = UInt16(parts.count > 1 ? Int(parts[1]) ?? Int(Proto.relayPort) : Int(Proto.relayPort))
        guard !host.isEmpty else { return finish(.unreachable) }
        // Relay requires a 64-char lowercase-hex pairHash (roomKey in main.go).
        let room = String((0..<64).map { _ in "0123456789abcdef".randomElement()! })

        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let ca = Conn(NWConnection(to: ep, using: Conn.tcpParameters()), label: "relay-health-a")
        let cb = Conn(NWConnection(to: ep, using: Conn.tcpParameters()), label: "relay-health-b")
        a = ca; b = cb

        ca.onData = { [weak self] d in guard let self else { return }; self.pa.feed(d); self.drain(self.pa) }
        cb.onData = { [weak self] d in guard let self else { return }; self.pb.feed(d); self.drain(self.pb) }

        ca.start { st in
            guard case .ready = st else { return }
            let reg = RelayRegister(v: 1, role: "sender", code: "", pairHash: room, token: token)
            ca.send(Wire.encodeJSON(.relayRegister, reg))
            // JOIN slightly after REGISTER so the room exists.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                cb.start { st2 in
                    guard case .ready = st2 else { return }
                    let join = RelayJoin(v: 1, role: "receiver", code: "", pairHash: room, token: token)
                    cb.send(Wire.encodeJSON(.relayJoin, join))
                }
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finish(.unreachable) }
    }

    private func drain(_ p: FrameParser) {
        while let frame = try? p.next() {
            if ProcessInfo.processInfo.environment["ND_HEALTH_DEBUG"] == "1" {
                Log.info("relay-health: frame type=0x\(String(frame.type, radix: 16)) len=\(frame.payload.count)")
            }
            guard let t = MsgType(rawValue: frame.type) else { continue }
            switch t {
            case .relayPaired:
                let ms = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
                finish(.ok(ms: ms))
            case .relayError:
                let reason = (try? JSONDecoder().decode(RelayError.self, from: frame.payload))?.reason ?? ""
                if ProcessInfo.processInfo.environment["ND_HEALTH_DEBUG"] == "1" { Log.info("relay-health: RELAY_ERROR reason=\(reason)") }
                finish(reason == "unauthorized" ? .unauthorized : .unreachable)
            default: break
            }
        }
    }

    private func finish(_ status: Status) {
        lock.lock(); if finished { lock.unlock(); return }; finished = true; lock.unlock()
        a?.close(); b?.close(); a = nil; b = nil
        completion(status)
        selfRef = nil   // allow deallocation
    }
}
