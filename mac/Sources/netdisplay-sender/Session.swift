import Foundation
import Network
import CoreGraphics

/// What to project. Mutable so the source can be switched live over one connection.
struct ProjectionSource {
    var windowApp: String?         // nil → whole desktop (virtual display); set → single window
    var stage: Bool = false        // window mode: move the window onto an off-main stage display
    var override = DisplayOverride()
    var prioritizeQuality = false
}

/// Application-layer session over a persistent connection (direct or relayed).
/// v1.4: the connection is long-lived; **projection** (what's being streamed) is
/// a sub-state that can start / stop / switch / bounce without reconnecting.
final class Session {
    private let conn: Conn
    private let parser = FrameParser()
    private let bitrateBps: Int
    private let bitrateExplicit: Bool
    private let senderName: String
    private let deviceId: String

    /// The current projection source (initial from init; can be switched live).
    private var source: ProjectionSource

    private var currentHello: HelloReceiver?
    private var helloReceived = false
    private var helloAckSent = false
    private var switching = false

    private var pipeline: StreamPipeline?
    private var stageDisplay: VirtualDisplay?
    private var stageFollowTimer: DispatchSourceTimer?
    private var currentStagePid: pid_t = 0
    private var currentStageWindowID: CGWindowID = 0

    private var lastRecv = Date()
    private var deadTimer: DispatchSourceTimer?

    var onEnd: (() -> Void)?
    /// (w, h, fps, scale) when a projection starts; nil-size sentinel not used —
    /// idle is reported via onIdle.
    var onStreaming: ((Int, Int, Int, Int) -> Void)?
    var onIdle: (() -> Void)?

    init(conn: Conn, bitrateBps: Int, senderName: String, deviceId: String,
         override: DisplayOverride = DisplayOverride(), prioritizeQuality: Bool = false,
         windowApp: String? = nil, bitrateExplicit: Bool = true, stage: Bool = false) {
        self.conn = conn
        self.bitrateBps = bitrateBps
        self.senderName = senderName
        self.deviceId = deviceId
        self.bitrateExplicit = bitrateExplicit
        self.source = ProjectionSource(windowApp: windowApp, stage: stage,
                                       override: override, prioritizeQuality: prioritizeQuality)
    }

    // MARK: - Connection lifecycle

    func begin() {
        conn.onData = { [weak self] data in self?.ingest(data) }
        conn.onClose = { [weak self] in self?.end(reason: "connection closed") }
        let hello = HelloSender(version: Proto.version, role: "sender", name: senderName, deviceId: deviceId)
        conn.send(Wire.encodeJSON(.hello, hello))
        Log.info("session: sent HELLO")
        startDeadTimer()
    }

    func feedRaw(_ data: Data) { if !data.isEmpty { ingest(data) } }

    private func startDeadTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastRecv) > 10 {
                Log.info("session: no data 10s, treating as dead")
                self.end(reason: "heartbeat timeout")
            }
        }
        deadTimer = t; t.resume()
    }

    private func ingest(_ data: Data) {
        lastRecv = Date()
        parser.feed(data)
        do { while let frame = try parser.next() { handle(frame) } }
        catch { Log.error("session: frame parse error \(error), closing"); end(reason: "protocol error") }
    }

    private func handle(_ frame: FrameParser.Frame) {
        guard let type = MsgType(rawValue: frame.type) else {
            Log.info("session: unknown frame type 0x\(String(frame.type, radix: 16)), skipping"); return
        }
        switch type {
        case .hello: handleHello(frame.payload)
        case .requestKeyframe: pipeline?.requestKeyframe()
        case .ping: conn.send(Wire.encode(.pong, frame.payload))
        case .control: handleControl(frame.payload)
        case .bye:
            let reason = (try? JSONDecoder().decode(ByeMsg.self, from: frame.payload))?.reason ?? ""
            Log.info("session: received BYE \(reason)"); end(reason: "peer BYE")
        default: break
        }
    }

    private func handleHello(_ payload: Data) {
        guard !helloReceived else { return }
        guard let hello = try? JSONDecoder().decode(HelloReceiver.self, from: payload) else {
            Log.error("session: bad HELLO json"); sendByeAndClose("bad hello"); return
        }
        helloReceived = true
        currentHello = hello
        Log.info("session: HELLO from \(hello.name ?? "?") screen=\(hello.screen.width)x\(hello.screen.height)@\(hello.screen.fps) scale=\(hello.screen.scale)")
        if hello.version != Proto.version {
            let ack = HelloAck(version: Proto.version, accepted: false, display: nil, codec: nil,
                               reason: "version mismatch", pairSecret: nil)
            conn.send(Wire.encodeJSON(.helloAck, ack)); sendByeAndClose("version mismatch"); return
        }
        // Start the initial projection (connection stays alive regardless).
        Task { await startProjection() }
    }

    private func handleControl(_ payload: Data) {
        guard let msg = try? JSONDecoder().decode(ControlMsg.self, from: payload) else { return }
        Log.info("session: CONTROL \(msg.action)")
        switch msg.action {
        case "bounceBack": Task { await stopProjection(bounceBack: true) }
        case "stop":       Task { await stopProjection(bounceBack: false) }
        default: break
        }
    }

    // MARK: - Projection control (v1.4)

    /// Switch the projected source live (no reconnect). Called by the controller/menu.
    func switchSource(to newSource: ProjectionSource) {
        Task {
            await stopProjection(bounceBack: true)
            self.source = newSource
            await startProjection()
        }
    }

    private func effectiveBitrate() -> Int {
        if bitrateExplicit { return bitrateBps }
        if let mbps = currentHello?.screen.bitrateMbps, mbps > 0 { return mbps * 1_000_000 }
        return bitrateBps
    }

    private func startProjection() async {
        guard !ended, helloReceived, pipeline == nil else { return }
        guard let hello = currentHello else { return }
        let fps = min(60, max(15, source.override.fps ?? hello.screen.fps))
        let effBitrate = effectiveBitrate()

        let pipe: StreamPipeline?
        let outW: Int, outH: Int, outScale: Int, label: String, kind: String

        if source.stage, let app = source.windowApp {
            // Stage-follow: put the chosen window on an off-main stage, then project
            // whichever window is frontmost on the stage (drag another on → it replaces).
            if !WindowMover.hasPermission(prompt: true) { rejectOrIdle("需要「辅助功能」权限才能把窗口移到扩展屏"); return }
            // HiDPI stage (3840×2400 @2x = 1920×1200 pt) so windows render retina-sharp.
            guard let vd = VirtualDisplay(name: "NetDisplay Stage", pixelWidth: 3840, pixelHeight: 2400, scale: 2) else {
                rejectOrIdle("无法创建扩展屏"); return
            }
            self.stageDisplay = vd
            let origin = CGDisplayBounds(vd.displayID).origin
            if let r = try? await WindowPicker.find(appName: app) {
                WindowMover.moveFrontWindow(pid: r.pid, to: CGPoint(x: origin.x + 24, y: origin.y + 24))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await projectFrontmostOnStage()   // initial projection
            startStageFollow()                // watch for dragged-in windows
            return
        }

        if let app = source.windowApp {
            pipe = await StreamPipeline.window(appName: app, fps: fps, bitrateBps: effBitrate,
                                               prioritizeQuality: source.prioritizeQuality)
            guard let p = pipe else { rejectOrIdle("无法投射窗口 '\(app)'（未找到可见窗口）"); return }
            outW = p.pixelWidth; outH = p.pixelHeight; outScale = 1
            label = "\(app) 窗口 \(outW)×\(outH)"; kind = "window"
            p.onReconfigure = { [weak self] nw, nh in self?.sendVideoConfig(width: nw, height: nh, fps: fps) }
        } else {
            // Whole desktop → virtual display.
            let w = (source.override.width ?? hello.screen.width) & ~1
            let h = (source.override.height ?? hello.screen.height) & ~1
            let scale = max(1, source.override.scale ?? hello.screen.scale)
            pipe = StreamPipeline(name: "NetDisplay", pixelWidth: w, pixelHeight: h, scale: scale,
                                  fps: fps, bitrateBps: effBitrate, deviceSeed: deviceId,
                                  prioritizeQuality: source.prioritizeQuality)
            guard let p = pipe else { rejectOrIdle("failed to create virtual display"); return }
            outW = w; outH = h; outScale = scale
            label = "整个桌面 \(w)×\(h)"; kind = "desktop"
            _ = p
        }
        guard let p = pipe, !ended else { return }
        p.onEncoded = { [weak self] ptsUs, key, annexB in self?.sendVideoFrame(ptsUs: ptsUs, isKeyframe: key, annexB: annexB) }
        self.pipeline = p

        // First projection uses HELLO_ACK; later switches use VIDEO_CONFIG (no reconnect).
        if !helloAckSent {
            let ack = HelloAck(version: Proto.version, accepted: true,
                               display: .init(width: outW, height: outH, fps: fps, scale: outScale),
                               codec: "h264", reason: nil, pairSecret: PairStore.ensureSecret())
            conn.send(Wire.encodeJSON(.helloAck, ack))
            helloAckSent = true
        } else {
            sendVideoConfig(width: outW, height: outH, fps: fps)
        }
        conn.send(Wire.encodeJSON(.projectionState, ProjectionState(active: true, label: label, sourceKind: kind)))
        Log.info("session: projecting \(label)")
        onStreaming?(outW, outH, fps, outScale)
        p.requestKeyframe()
        do { try await p.start() }
        catch { Log.error("session: capture start failed \(error)"); await stopProjection(bounceBack: true) }
    }

    /// Project whatever window is frontmost on the stage display now.
    private func projectFrontmostOnStage() async {
        guard !ended, let vd = stageDisplay, let hello = currentHello else { return }
        let bounds = CGDisplayBounds(vd.displayID)
        guard let r = await WindowPicker.frontmostOnDisplay(bounds) else {
            // Nothing on the stage → idle.
            if pipeline != nil { pipeline?.stop(); pipeline = nil
                if helloAckSent { conn.send(Wire.encodeJSON(.projectionState, ProjectionState(active: false, label: nil, sourceKind: nil))) } }
            currentStageWindowID = 0; currentStagePid = 0
            return
        }
        if r.window.windowID == currentStageWindowID { return } // unchanged

        let fps = min(60, max(15, source.override.fps ?? hello.screen.fps))
        guard let p = StreamPipeline.window(scWindow: r.window, pixelWidth: r.pixelWidth, pixelHeight: r.pixelHeight,
                                            fps: fps, bitrateBps: effectiveBitrate(), prioritizeQuality: source.prioritizeQuality) else { return }
        // Bounce the previously-projected window back to the main screen.
        if currentStagePid != 0 && currentStagePid != r.pid {
            WindowMover.moveFrontWindow(pid: currentStagePid, to: CGPoint(x: 120, y: 120))
        }
        pipeline?.stop()
        p.onEncoded = { [weak self] pts, key, data in self?.sendVideoFrame(ptsUs: pts, isKeyframe: key, annexB: data) }
        p.onReconfigure = { [weak self] nw, nh in self?.sendVideoConfig(width: nw, height: nh, fps: fps) }
        self.pipeline = p
        currentStageWindowID = r.window.windowID; currentStagePid = r.pid
        let name = r.window.owningApplication?.applicationName ?? "窗口"
        if !helloAckSent {
            conn.send(Wire.encodeJSON(.helloAck, HelloAck(version: Proto.version, accepted: true,
                display: .init(width: r.pixelWidth, height: r.pixelHeight, fps: fps, scale: 1), codec: "h264", reason: nil, pairSecret: PairStore.ensureSecret())))
            helloAckSent = true
        } else {
            sendVideoConfig(width: r.pixelWidth, height: r.pixelHeight, fps: fps)
        }
        conn.send(Wire.encodeJSON(.projectionState, ProjectionState(active: true, label: "\(name) \(r.pixelWidth)×\(r.pixelHeight)", sourceKind: "window")))
        Log.info("session: stage projecting \(name) \(r.pixelWidth)×\(r.pixelHeight)")
        onStreaming?(r.pixelWidth, r.pixelHeight, fps, 1)
        p.requestKeyframe()
        do { try await p.start() } catch { Log.error("session: stage capture start failed \(error)") }
    }

    private func startStageFollow() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 0.6, repeating: 0.6)
        t.setEventHandler { [weak self] in Task { await self?.projectFrontmostOnStage() } }
        stageFollowTimer = t; t.resume()
    }

    private func stopProjection(bounceBack: Bool) async {
        stageFollowTimer?.cancel(); stageFollowTimer = nil
        currentStageWindowID = 0; currentStagePid = 0
        pipeline?.stop(); pipeline = nil
        if let vd = stageDisplay {  // reaping the stage returns any window on it to the main screen
            stageDisplay = nil
            VirtualDisplay.reap(vd)
        }
        if helloAckSent && !ended {
            conn.send(Wire.encodeJSON(.projectionState, ProjectionState(active: false, label: nil, sourceKind: nil)))
        }
        Log.info("session: projection stopped (bounceBack=\(bounceBack)), idle")
        onIdle?()
    }

    /// On the very first projection a failure must reject the HELLO; after that,
    /// just go idle (keep the connection/window alive).
    private func rejectOrIdle(_ reason: String) {
        if !helloAckSent {
            let ack = HelloAck(version: Proto.version, accepted: false, display: nil, codec: nil,
                               reason: reason, pairSecret: nil)
            conn.send(Wire.encodeJSON(.helloAck, ack))
            sendByeAndClose(reason)
        } else {
            Log.error("session: projection failed (\(reason)); staying idle")
            if let vd = stageDisplay { stageDisplay = nil; VirtualDisplay.reap(vd) }
            conn.send(Wire.encodeJSON(.projectionState, ProjectionState(active: false, label: nil, sourceKind: nil)))
            onIdle?()
        }
    }

    // MARK: - Send helpers

    private func sendVideoFrame(ptsUs: UInt64, isKeyframe: Bool, annexB: Data) {
        if !isKeyframe && conn.inFlight > 5 { pipeline?.requestKeyframe(); return }
        let payload = VideoFramePayload.build(ptsUs: ptsUs, isKeyframe: isKeyframe, annexB: annexB)
        conn.send(Wire.encode(.videoFrame, payload), tracked: true)
    }

    private func sendVideoConfig(width: Int, height: Int, fps: Int) {
        let cfg = VideoConfig(codec: "h264", width: width, height: height, fps: fps, bitrateMbps: effectiveBitrate() / 1_000_000)
        conn.send(Wire.encodeJSON(.videoConfig, cfg))
        Log.info("session: sent VIDEO_CONFIG \(width)x\(height)")
    }

    private func sendByeAndClose(_ reason: String) {
        conn.send(Wire.encodeJSON(.bye, ByeMsg(reason: reason)))
        end(reason: reason)
    }

    private var ended = false
    func end(reason: String) {
        if ended { return }
        ended = true
        Log.info("session ended: \(reason)")
        deadTimer?.cancel(); deadTimer = nil
        stageFollowTimer?.cancel(); stageFollowTimer = nil
        pipeline?.stop(); pipeline = nil
        if let vd = stageDisplay { stageDisplay = nil; VirtualDisplay.reap(vd) }
        conn.close()
        onEnd?()
    }
}
