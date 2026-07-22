import Foundation
import Network

/// Thin wrapper over NWConnection: TCP_NODELAY, a receive loop, and send with
/// an in-flight counter for coarse backpressure.
final class Conn {
    let nw: NWConnection
    private let queue: DispatchQueue

    private let inFlightLock = NSLock()
    private(set) var sendInFlight = 0

    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(_ connection: NWConnection, label: String) {
        self.nw = connection
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// Build TCP parameters with Nagle disabled (critical for latency).
    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        return params
    }

    func start(stateHandler: ((NWConnection.State) -> Void)? = nil) {
        nw.stateUpdateHandler = { [weak self] state in
            stateHandler?(state)
            switch state {
            case .failed, .cancelled:
                self?.handleClose()
            default:
                break
            }
        }
        nw.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onData?(data)
            }
            if isComplete || error != nil {
                self.handleClose()
                return
            }
            self.receiveLoop()
        }
    }

    func send(_ data: Data, tracked: Bool = false) {
        if tracked {
            inFlightLock.lock(); sendInFlight += 1; inFlightLock.unlock()
        }
        nw.send(content: data, completion: .contentProcessed { [weak self] _ in
            if tracked {
                self?.inFlightLock.lock(); self?.sendInFlight -= 1; self?.inFlightLock.unlock()
            }
        })
    }

    var inFlight: Int {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return sendInFlight
    }

    private func handleClose() {
        if closed { return }
        closed = true
        onClose?()
    }

    func close() {
        if closed { return }
        closed = true
        nw.cancel()
    }
}
