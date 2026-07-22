import Foundation
import Network
import CoreMedia
import CoreVideo

/// Mac Receiver (symmetric app's receive half). Dials a Sender in direct mode,
/// performs the Receiver handshake, decodes the incoming H.264/HEVC stream, and
/// reports stats. Decoded frames are handed to `onFrame` for a renderer (a later
/// step wires an NSWindow); this headless core unblocks Windows-Sender → Mac
/// interop of the network + decode path.
final class ReceiverSession {
    private let host: String
    private let port: UInt16
    private let name: String
    private let deviceId: String
    private let screen: HelloReceiver.Screen
    private let codecs: [String]

    private var conn: Conn?
    private let parser = FrameParser()
    private var decoder: Decoder?
    private var chosenCodec: VideoCodec = .h264

    private var pingTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var lastRx = Date()
    private var ended = false

    // Stats. `bytesAnnexB` counts the Annex-B payload only (excludes the 9-byte
    // pts+flags VIDEO_FRAME header) — same convention as the Windows Sender's
    // `bytes`, so cross-platform accounting lines up.
    private let statLock = NSLock()
    private var framesDecoded = 0, framesTotal = 0, decodeErrors = 0
    private var bytesAnnexB = 0
    private var statsTimer: DispatchSourceTimer?
    // Cumulative totals for RECV_STATS export (mirror of Windows SEND_STATS).
    private var cumRecv = 0, cumDecoded = 0, cumErrors = 0, cumBytes = 0, cumKeyframes = 0, cumDropped = 0

    // Receiver-side backpressure. When VT's async decode queue is *genuinely*
    // backed up (high RTT / slow decode), drop delta frames until the next
    // keyframe AND proactively request one, so recovery is ~1 RTT, not a full GOP.
    //
    // Per Windows' cross-machine finding: over a 400-600ms relay, TCP delivers
    // frames in bursts (a dozen at once), so the queue spikes transiently but
    // drains fast. Dropping on the *instantaneous* depth misreads a burst as
    // congestion and self-sustains a drop→request-keyframe→wait-RTT→drop loop.
    // So: high threshold + require several *consecutive* over-limit samples
    // before deciding it's real congestion. Invisible at loopback RTT<1ms.
    private let decodeBacklogLimit = 24
    private let backlogSamplesToTrip = 3
    private var consecutiveOverLimit = 0
    private var waitingKey = false
    private var lastKeyframeReq = Date.distantPast
    private var streamW = 0, streamH = 0
    private var emitStatsTimer: DispatchSourceTimer?
    /// If set, emit `RECV_STATS {json}` to stdout every N seconds (cumulative).
    var statsEmitSec: Int?
    /// If false and statsEmitSec set, emit exactly once then stop.
    var statsRepeat = true

    /// Decoded frame sink for a future renderer.
    var onFrame: ((_ image: CVImageBuffer, _ pts: CMTime) -> Void)?
    /// Called once the handshake is accepted (display dimensions, negotiated codec).
    var onReady: ((_ display: HelloAck.Display?, _ codec: VideoCodec) -> Void)?
    var onClosed: (() -> Void)?

    init(host: String, port: UInt16, name: String, deviceId: String,
         screen: HelloReceiver.Screen, codecs: [String]) {
        self.host = host
        self.port = port
        self.name = name
        self.deviceId = deviceId
        self.screen = screen
        self.codecs = codecs
    }

    /// Direct mode: create the connection to the Sender, then run the protocol.
    func start() {
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                     port: NWEndpoint.Port(rawValue: port)!)
        let nw = NWConnection(to: ep, using: Conn.tcpParameters())
        let c = Conn(nw, label: "netdisplay.receiver")
        c.onData = { [weak self] in self?.onData($0) }
        c.onClose = { [weak self] in self?.handleClose() }
        conn = c
        c.start { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("receiver connected to \(self.host):\(self.port)")
                self.beginProtocol(leftover: nil)
            case .failed(let e):
                Log.error("receiver connection failed: \(e)")
                self.handleClose()
            default:
                break
            }
        }
    }

    /// Relay mode: the pipe is already connected + transparent (post RELAY_PAIRED).
    /// Take over the Conn and run the same protocol. `leftover` = any post-pairing
    /// bytes already read by the relay parser.
    func attach(conn: Conn, leftover: Data) {
        self.conn = conn
        conn.onData = { [weak self] in self?.onData($0) }
        conn.onClose = { [weak self] in self?.handleClose() }
        beginProtocol(leftover: leftover)
    }

    private func beginProtocol(leftover: Data?) {
        Log.info("receiver: sending HELLO")
        sendHello()
        startTimers()
        if let leftover, !leftover.isEmpty { onData(leftover) }
    }

    private func sendHello() {
        let hello = HelloReceiver(version: Proto.version, role: "receiver", name: name,
                                  deviceId: deviceId, screen: screen, codecs: codecs)
        conn?.send(Wire.encodeJSON(.hello, hello))
    }

    // MARK: Receive

    private func onData(_ data: Data) {
        lastRx = Date()
        parser.feed(data)
        do {
            while let frame = try parser.next() {
                handleFrame(frame)
            }
        } catch {
            Log.error("receiver frame parse error: \(error) — closing")
            close()
        }
    }

    private func handleFrame(_ frame: FrameParser.Frame) {
        guard let type = MsgType(rawValue: frame.type) else { return }
        switch type {
        case .helloAck:      handleHelloAck(frame.payload)
        case .videoConfig:   handleVideoConfig(frame.payload)
        case .videoFrame:    handleVideoFrame(frame.payload)
        case .projectionState:
            if let ps = try? JSONDecoder().decode(ProjectionState.self, from: frame.payload) {
                Log.info("projection: active=\(ps.active) label=\(ps.label ?? "-") kind=\(ps.sourceKind ?? "-")")
            }
        case .ping:
            conn?.send(Wire.encode(.pong, frame.payload)) // echo payload back
        case .pong:
            break
        case .bye:
            let reason = (try? JSONDecoder().decode(ByeMsg.self, from: frame.payload))?.reason ?? "?"
            Log.info("sender said BYE: \(reason)"); close()
        default:
            break
        }
    }

    private func handleHelloAck(_ payload: Data) {
        guard let ack = try? JSONDecoder().decode(HelloAck.self, from: payload) else { return }
        guard ack.accepted else {
            Log.error("handshake rejected: \(ack.reason ?? "?")"); close(); return
        }
        chosenCodec = VideoCodec(rawValue: ack.codec ?? "h264") ?? .h264
        // Persist the peer-issued pairSecret so future relay JOINs can go code-free.
        if let secret = ack.pairSecret, !secret.isEmpty {
            PairStore.saveSecret(secret, slot: "receiver")
            Log.info("pairing: stored peer pairSecret (relay JOIN will be code-free next time)")
        }
        makeDecoder(codec: chosenCodec)
        if let d = ack.display {
            statLock.lock(); streamW = d.width; streamH = d.height; statLock.unlock()
            Log.info("handshake OK — stream \(d.width)x\(d.height)@\(d.fps) scale=\(d.scale ?? 1) codec=\(chosenCodec.wire)")
        }
        onReady?(ack.display, chosenCodec)
        // Nudge a keyframe so decode can start immediately.
        conn?.send(Wire.encode(.requestKeyframe))
    }

    private func handleVideoConfig(_ payload: Data) {
        guard let cfg = try? JSONDecoder().decode(VideoConfig.self, from: payload) else { return }
        let newCodec = VideoCodec(rawValue: cfg.codec) ?? chosenCodec
        Log.info("VIDEO_CONFIG → \(cfg.width)x\(cfg.height)@\(cfg.fps) \(cfg.codec) — resetting decoder")
        chosenCodec = newCodec
        makeDecoder(codec: newCodec)              // fresh decoder waits for the next keyframe
        conn?.send(Wire.encode(.requestKeyframe))
    }

    private func handleVideoFrame(_ payload: Data) {
        guard payload.count >= 9 else { return }
        let ptsUs = payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let isKey = (payload[payload.index(payload.startIndex, offsetBy: 8)] & 0x01) != 0
        let annexB = payload.subdata(in: payload.index(payload.startIndex, offsetBy: 9)..<payload.endIndex)
        statLock.lock()
        framesTotal += 1; bytesAnnexB += annexB.count
        cumRecv += 1; cumBytes += annexB.count; if isKey { cumKeyframes += 1 }
        statLock.unlock()

        // Backpressure. Once dropping, keep dropping deltas until a keyframe lands.
        let pending = decoder?.pending ?? 0
        if waitingKey {
            if isKey { waitingKey = false; consecutiveOverLimit = 0 } else { dropFrame(); return }
        } else {
            // Count consecutive over-limit frames so a transient burst (which
            // drains within a frame or two) doesn't trip the drop loop.
            consecutiveOverLimit = pending >= decodeBacklogLimit ? consecutiveOverLimit + 1 : 0
            if consecutiveOverLimit >= backlogSamplesToTrip && !isKey {
                waitingKey = true
                requestKeyframeThrottled()
                dropFrame(); return
            }
        }
        decoder?.decode(annexB: annexB, ptsUs: ptsUs)
    }

    private func dropFrame() {
        statLock.lock(); cumDropped += 1; statLock.unlock()
    }

    /// Ask the Sender for a fresh IDR, at most once per second.
    private func requestKeyframeThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeReq) >= 1.0 else { return }
        lastKeyframeReq = now
        conn?.send(Wire.encode(.requestKeyframe))
    }

    private func makeDecoder(codec: VideoCodec) {
        let d = Decoder(codec: codec)
        d.onDecoded = { [weak self] image, pts in
            guard let self else { return }
            self.statLock.lock(); self.framesDecoded += 1; self.cumDecoded += 1; self.statLock.unlock()
            self.onFrame?(image, pts)
        }
        d.onDecodeError = { [weak self] st in
            guard let self else { return }
            self.statLock.lock(); self.decodeErrors += 1; self.cumErrors += 1; self.statLock.unlock()
            self.conn?.send(Wire.encode(.requestKeyframe))  // ask for a fresh IDR
            if self.decodeErrors <= 3 { Log.info("decode error \(st) → REQUEST_KEYFRAME") }
        }
        decoder = d
    }

    // MARK: Timers

    private func startTimers() {
        // PING every 3s (8 random bytes; Sender echoes as PONG).
        let ping = DispatchSource.makeTimerSource(queue: .global())
        ping.schedule(deadline: .now() + 3, repeating: 3)
        ping.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 { bytes[i] = UInt8.random(in: 0...255) }
            self?.conn?.send(Wire.encode(.ping, Data(bytes)))
        }
        pingTimer = ping; ping.resume()

        // Watchdog: 10s with no data → dead connection.
        let wd = DispatchSource.makeTimerSource(queue: .global())
        wd.schedule(deadline: .now() + 2, repeating: 2)
        wd.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastRx) > 10 {
                Log.error("watchdog: no data 10s — closing"); self.close()
            }
        }
        watchdog = wd; wd.resume()

        // Stats once a second.
        let st = DispatchSource.makeTimerSource(queue: .global())
        st.schedule(deadline: .now() + 1, repeating: 1)
        st.setEventHandler { [weak self] in
            guard let self else { return }
            self.statLock.lock()
            let d = self.framesDecoded, t = self.framesTotal, e = self.decodeErrors, b = self.bytesAnnexB
            let drp = self.cumDropped
            self.framesDecoded = 0; self.framesTotal = 0; self.bytesAnnexB = 0
            self.statLock.unlock()
            let mbps = Double(b) * 8 / 1_000_000
            Log.info(String(format: "recv: frames=%d/s decoded=%d/s dropped=%d errors=%d %.2fMbps(annexb)", t, d, drp, e, mbps))
        }
        statsTimer = st; st.resume()

        // Optional machine-readable RECV_STATS export (mirror of Windows SEND_STATS).
        if let sec = statsEmitSec, sec > 0 {
            let et = DispatchSource.makeTimerSource(queue: .global())
            et.schedule(deadline: .now() + Double(sec), repeating: statsRepeat ? Double(sec) : .infinity)
            et.setEventHandler { [weak self] in
                guard let self else { return }
                print("RECV_STATS \(self.statsJSON())"); fflush(stdout)
                if !self.statsRepeat { self.emitStatsTimer?.cancel() }
            }
            emitStatsTimer = et; et.resume()
        }
    }

    /// Cumulative stats as JSON. `bytes` = Annex-B payload only (matches the
    /// Windows Sender's `bytes`), so `recv`≈Sender `sent`, `bytes`≈Sender `bytes`.
    func statsJSON() -> String {
        statLock.lock()
        let obj: [String: Any] = [
            "recv": cumRecv, "decoded": cumDecoded, "dropped": cumDropped, "errors": cumErrors,
            "keyframes": cumKeyframes, "bytes": cumBytes,
            "codec": chosenCodec.wire, "width": streamW, "height": streamH
        ]
        statLock.unlock()
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func handleClose() {
        guard !ended else { return }
        ended = true
        pingTimer?.cancel(); watchdog?.cancel(); statsTimer?.cancel(); emitStatsTimer?.cancel()
        // Final line so a one-shot run always prints totals before exit.
        if statsEmitSec != nil { print("RECV_STATS \(statsJSON())"); fflush(stdout) }
        decoder = nil
        onClosed?()
    }

    func close() {
        conn?.send(Wire.encodeJSON(.bye, ByeMsg(reason: "receiver closed")))
        conn?.close()
        handleClose()
    }
}
