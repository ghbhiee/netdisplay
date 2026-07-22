import Foundation

// MARK: - CLI

func usage() -> Never {
    let exe = "netdisplay-sender"
    print("""
    NetDisplay Sender (macOS) — 把 Mac 虚拟屏串流到 Windows

    用法:
      \(exe)                菜单栏 App（无参数直接跑，状态栏可改配置、实时生效）
      \(exe) app            同上，显式启动菜单栏 App

      \(exe) listen [--port 47800] [--debug-raw] [--bitrate 40]
                    [--width W] [--height H] [--scale S]
          直连模式：监听 47800，Receiver 拨入后按其 HELLO 创建虚拟屏推流。
          --scale S：HiDPI 缩放。S=2 让 macOS 按「宽/2 × 高/2」逻辑点渲染（字更大更清晰），
                     画面像素仍是原分辨率。--width/--height 强制虚拟屏分辨率（覆盖 Receiver 上报值）。
          --debug-raw：M1 验收模式，立即创建虚拟屏并在 47801 推裸 Annex-B H.264。

      \(exe) relay [--server 15.tokencv.com:47700] [--bitrate 10]
                   [--width W] [--height H] [--scale S]
          中转模式：连 relay，打印 6 位配对码，配对后推流。--scale/--width/--height 同上。

      \(exe) vd-demo [--width 2560 --height 1600 --scale 1 --seconds 20]
          调试：只建虚拟屏，每秒打印它的 mode/bounds/mirror 状态，观察系统是否回退。

      \(exe) capture-demo [--width 2560 --height 1600 --scale 1 --out /tmp/vd.png]
          调试：建虚拟屏并抓一帧存 PNG，看「增加的屏幕」上到底渲染了什么（桌面/菜单栏/黑屏）。

    """)
    exit(2)
}

struct Args {
    var command: String
    var flags: [String: String] = [:]
    var bools: Set<String> = []

    func str(_ k: String, _ d: String) -> String { flags[k] ?? d }
    func int(_ k: String, _ d: Int) -> Int { flags[k].flatMap { Int($0) } ?? d }
    func bool(_ k: String) -> Bool { bools.contains(k) }
}

func parseArgs() -> Args {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard !argv.isEmpty else { usage() }
    let command = argv.removeFirst()
    var a = Args(command: command)
    let boolFlags: Set<String> = ["debug-raw", "quality", "stage"]
    var i = 0
    while i < argv.count {
        let tok = argv[i]
        guard tok.hasPrefix("--") else { i += 1; continue }
        let key = String(tok.dropFirst(2))
        if boolFlags.contains(key) {
            a.bools.insert(key)
            i += 1
        } else if i + 1 < argv.count {
            a.flags[key] = argv[i + 1]
            i += 2
        } else {
            i += 1
        }
    }
    return a
}

// MARK: - Identity

func deviceId() -> String {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".netdisplay-sender")
    let file = dir.appendingPathComponent("deviceId")
    if let existing = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !existing.isEmpty {
        return existing
    }
    let id = UUID().uuidString
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? id.write(to: file, atomically: true, encoding: .utf8)
    return id
}

func senderName() -> String {
    Host.current().localizedName ?? "MacBook"
}

/// Build a display override from CLI flags — nil for any flag not given, so the
/// Receiver's HELLO request is honored when unset.
func overrideFromArgs(_ a: Args) -> DisplayOverride {
    DisplayOverride(
        width: a.flags["width"].flatMap { Int($0) },
        height: a.flags["height"].flatMap { Int($0) },
        scale: a.flags["scale"].flatMap { Int($0) },
        fps: a.flags["fps"].flatMap { Int($0) }
    )
}

// MARK: - Signal handling

func installSignalHandler(_ onSignal: @escaping () -> Void) {
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    src.setEventHandler { onSignal() }
    src.resume()
    signal(SIGINT, SIG_IGN)
    // Keep a strong reference alive.
    signalSource = src
}
var signalSource: DispatchSourceSignal?
var usr1HoldSource: DispatchSourceSignal?

// MARK: - Main

let name = senderName()
let devId = deviceId()

// No subcommand (e.g. double-clicked) or `app` → run the menu-bar app.
let rawArgs = Array(CommandLine.arguments.dropFirst())
if rawArgs.isEmpty || rawArgs.first == "app" {
    MenuBarApp(senderName: name, deviceId: devId).run() // runs NSApplication; never returns
    exit(0)
}

let args = parseArgs()

switch args.command {
case "listen":
    if args.bool("debug-raw") {
        // Standalone M1 verification path: create the virtual display now and
        // stream bare Annex-B on 47801.
        let w = args.int("width", 2560)
        let h = args.int("height", 1600)
        let scale = args.int("scale", 1)
        let fps = args.int("fps", 60)
        let bitrate = args.int("bitrate", 40) * 1_000_000
        Log.info("debug-raw mode: \(w)x\(h) scale=\(scale) @\(fps) \(bitrate/1_000_000)Mbps")

        let pipeline: StreamPipeline
        if let app = args.flags["window"] {
            // Window-projection debug: capture one app window instead of a virtual display.
            let sem = DispatchSemaphore(value: 0)
            var built: StreamPipeline?
            Task {
                built = await StreamPipeline.window(appName: app, fps: fps, bitrateBps: bitrate,
                                                    prioritizeQuality: args.bool("quality"))
                sem.signal()
            }
            sem.wait()
            guard let p = built else { Log.error("window projection init failed"); exit(1) }
            pipeline = p
        } else {
            guard let p = StreamPipeline(name: "NetDisplay", pixelWidth: w, pixelHeight: h,
                                         scale: scale, fps: fps, bitrateBps: bitrate, deviceSeed: devId) else {
                Log.error("pipeline init failed (screen-recording permission?)"); exit(1)
            }
            pipeline = p
        }

        let raw = DebugRawServer(port: Proto.debugRawPort)
        raw.onNewClient = { pipeline.requestKeyframe() }
        pipeline.onEncoded = { _, _, annexB in raw.broadcast(annexB) }
        do { try raw.start() } catch { Log.error("raw server failed: \(error)"); exit(1) }

        installSignalHandler {
            Log.info("shutting down…")
            pipeline.stop()
            exit(0)
        }
        Task {
            do { try await pipeline.start() }
            catch { Log.error("capture start failed: \(error) — grant Screen Recording to your terminal and retry"); exit(1) }
        }
        Log.info("ready. Connect: ffplay -fflags nobuffer -flags low_delay -f h264 tcp://127.0.0.1:\(Proto.debugRawPort)")
        dispatchMain()
    } else {
        let port = UInt16(args.int("port", Int(Proto.directPort)))
        let bitrate = args.int("bitrate", 40) * 1_000_000
        let server = SessionServer(port: port, bitrateBps: bitrate, senderName: name,
                                   deviceId: devId, override: overrideFromArgs(args),
                                   prioritizeQuality: args.bool("quality"), windowApp: args.flags["window"],
                                   bitrateExplicit: args.flags["bitrate"] != nil, stage: args.bool("stage"))
        do { try server.start() } catch { Log.error("listen failed: \(error)"); exit(1) }
        installSignalHandler { Log.info("bye"); exit(0) }
        // SIGUSR1: live-switch the current projection (window ↔ desktop) — tests
        // that switching the source does NOT reconnect.
        var usr1Toggled = false
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1.setEventHandler {
            usr1Toggled.toggle()
            let src = ProjectionSource(windowApp: usr1Toggled ? nil : args.flags["window"],
                                       stage: false, override: overrideFromArgs(args),
                                       prioritizeQuality: args.bool("quality"))
            server.currentSession?.switchSource(to: src)
            Log.info("SIGUSR1: live-switched source (window=\(src.windowApp ?? "desktop"))")
        }
        signal(SIGUSR1, SIG_IGN); usr1.resume(); usr1HoldSource = usr1
        Log.info("direct mode: waiting for Receiver on :\(port)")
        dispatchMain()
    }

case "relay":
    let server = args.str("server", "15.tokencv.com:\(Proto.relayPort)")
    let parts = server.split(separator: ":")
    let host = String(parts.first ?? "15.tokencv.com")
    let port = UInt16(parts.count > 1 ? Int(parts[1]) ?? Int(Proto.relayPort) : Int(Proto.relayPort))
    let bitrate = args.int("bitrate", 10) * 1_000_000
    let client = RelayClient(host: host, port: port, bitrateBps: bitrate, senderName: name,
                             deviceId: devId, token: args.flags["token"], override: overrideFromArgs(args),
                             prioritizeQuality: args.bool("quality"), windowApp: args.flags["window"],
                             bitrateExplicit: args.flags["bitrate"] != nil, stage: args.bool("stage"))
    installSignalHandler { Log.info("bye"); exit(0) }
    client.start()
    Log.info("relay mode: connecting to \(host):\(port)")
    dispatchMain()

case "vd-demo":
    Demos.vdDemo(pixelWidth: args.int("width", 2560), pixelHeight: args.int("height", 1600),
                 scale: args.int("scale", 1), seconds: args.int("seconds", 20), seed: devId)

case "capture-demo":
    Demos.captureDemo(pixelWidth: args.int("width", 2560), pixelHeight: args.int("height", 1600),
                      scale: args.int("scale", 1), out: args.str("out", "/tmp/vd.png"), seed: devId)

default:
    usage()
}
