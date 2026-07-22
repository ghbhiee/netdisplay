import Foundation
import Network

/// Debug raw stream (protocol §8): listen on :47801 and push a bare Annex-B
/// H.264 byte stream (no framing, no pts) to any client. For `ffplay` M1 checks.
final class DebugRawServer {
    private let port: UInt16
    private var listener: NWListener?
    private let clientsLock = NSLock()
    private var clients: [Conn] = []

    /// Invoked when a new client connects, so the caller can force a keyframe
    /// (a client joining mid-stream needs fresh SPS/PPS + IDR to start decoding).
    var onNewClient: (() -> Void)?

    init(port: UInt16) { self.port = port }

    func start() throws {
        let listener = try NWListener(using: Conn.tcpParameters(), on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] nwConn in
            guard let self else { return }
            Log.info("debug-raw: client connected \(nwConn.endpoint)")
            let conn = Conn(nwConn, label: "netdisplay.rawclient")
            conn.onClose = { [weak self] in self?.remove(conn) }
            conn.start()
            self.clientsLock.lock(); self.clients.append(conn); self.clientsLock.unlock()
            self.onNewClient?()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Log.info("debug-raw: listening on :\(self.port) (ffplay -f h264 tcp://127.0.0.1:\(self.port))")
            case .failed(let e): Log.error("debug-raw: listener failed \(e)")
            default: break
            }
        }
        listener.start(queue: .global(qos: .userInteractive))
        self.listener = listener
    }

    /// Push raw Annex-B bytes (no protocol framing) to all connected clients.
    func broadcast(_ annexB: Data) {
        clientsLock.lock(); let snapshot = clients; clientsLock.unlock()
        for c in snapshot {
            if c.inFlight > 8 { continue } // drop for slow raw clients
            c.send(annexB, tracked: true)
        }
    }

    private func remove(_ conn: Conn) {
        clientsLock.lock()
        clients.removeAll { $0 === conn }
        clientsLock.unlock()
    }

    var hasClients: Bool {
        clientsLock.lock(); defer { clientsLock.unlock() }
        return !clients.isEmpty
    }
}
