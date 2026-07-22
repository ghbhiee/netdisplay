import Foundation
import Network

/// Direct mode: listen on :47800, accept one Receiver at a time (new connection
/// kicks the old), and run a Session over it.
final class SessionServer {
    private let port: UInt16
    private let bitrateBps: Int
    private let senderName: String
    private let deviceId: String
    private let override: DisplayOverride
    private let prioritizeQuality: Bool
    private let windowApp: String?
    private let bitrateExplicit: Bool
    private let stage: Bool
    private var listener: NWListener?
    private var current: Session?

    var onState: ((SenderState) -> Void)?
    var currentSession: Session? { current }

    init(port: UInt16, bitrateBps: Int, senderName: String, deviceId: String,
         override: DisplayOverride = DisplayOverride(), prioritizeQuality: Bool = false,
         windowApp: String? = nil, bitrateExplicit: Bool = true, stage: Bool = false) {
        self.port = port
        self.bitrateBps = bitrateBps
        self.senderName = senderName
        self.deviceId = deviceId
        self.override = override
        self.prioritizeQuality = prioritizeQuality
        self.windowApp = windowApp
        self.bitrateExplicit = bitrateExplicit
        self.stage = stage
    }

    func start() throws {
        let params = Conn.tcpParameters()
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] nwConn in
            guard let self else { return }
            Log.info("direct: incoming connection from \(nwConn.endpoint)")
            self.current?.end(reason: "replaced by new connection")
            let conn = Conn(nwConn, label: "netdisplay.session")
            let session = Session(conn: conn, bitrateBps: self.bitrateBps,
                                  senderName: self.senderName, deviceId: self.deviceId,
                                  override: self.override, prioritizeQuality: self.prioritizeQuality,
                                  windowApp: self.windowApp, bitrateExplicit: self.bitrateExplicit,
                                  stage: self.stage)
            session.onStreaming = { [weak self] w, h, fps, scale in
                self?.onState?(.streaming(w: w, h: h, fps: fps, scale: scale))
            }
            session.onEnd = { [weak self] in
                if self?.current === session {
                    self?.current = nil
                    self?.onState?(.listening(port: Int(self?.port ?? 0)))
                }
            }
            self.current = session
            conn.start()
            session.begin()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Log.info("direct: listening on :\(self.port)")
            case .failed(let e): Log.error("direct: listener failed \(e)")
            default: break
            }
        }
        listener.start(queue: .global(qos: .userInteractive))
        self.listener = listener
    }

    func stop() {
        listener?.cancel(); listener = nil
        current?.end(reason: "stopped by user"); current = nil
    }
}
