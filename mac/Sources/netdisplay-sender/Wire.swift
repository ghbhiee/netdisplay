import Foundation
import Network

// MARK: - Protocol constants (source of truth: 02-protocol.md)

enum Proto {
    static let version = 1
    static let maxPayload = 16 * 1024 * 1024 // 16 MiB

    // Ports
    static let directPort: UInt16 = 47800
    static let debugRawPort: UInt16 = 47801
    static let relayPort: UInt16 = 47700
}

enum MsgType: UInt8 {
    case hello = 0x01
    case helloAck = 0x02
    case videoFrame = 0x10
    case requestKeyframe = 0x11
    case videoConfig = 0x12
    case projectionState = 0x13
    case inputEvent = 0x20
    case control = 0x21
    case ping = 0x30
    case pong = 0x31
    case bye = 0x3F
    case relayRegister = 0x40
    case relayJoin = 0x41
    case relayPaired = 0x42
    case relayError = 0x43
    case pairAnnounce = 0x44   // v1.12: mutual pairing
    case pairConfirmed = 0x45
    case probe = 0x46          // v1.13: direct-connectivity probe
    case probeAck = 0x47
    case presence = 0x48       // v1.14: peer presence
    case peerPresence = 0x49
}

// MARK: - Frame encoding

enum Wire {
    /// Serialize one protocol frame: [type u8][length u32 BE][payload].
    static func encode(_ type: UInt8, _ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(type)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func encode(_ type: MsgType, _ payload: Data = Data()) -> Data {
        encode(type.rawValue, payload)
    }

    static func encodeJSON<T: Encodable>(_ type: MsgType, _ value: T) -> Data {
        let payload = (try? JSONEncoder().encode(value)) ?? Data()
        return encode(type, payload)
    }
}

// MARK: - Streaming frame parser (handles TCP coalescing / partial frames)

/// Accumulates bytes and yields complete frames. Not thread-safe; drive it
/// from a single connection-receive callback.
final class FrameParser {
    private var buffer = Data()

    struct Frame {
        let type: UInt8
        let payload: Data
    }

    enum ParseError: Error { case payloadTooLarge }

    func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Return and clear any bytes not yet consumed as a complete frame. Used at
    /// the relay→session handoff to forward already-arrived post-pairing bytes.
    func drainRemaining() -> Data {
        let d = buffer
        buffer = Data()
        return d
    }

    /// Pull the next complete frame, or nil if more bytes are needed.
    func next() throws -> Frame? {
        guard buffer.count >= 5 else { return nil }
        let type = buffer[buffer.startIndex]
        let lenBytes = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: 1)..<buffer.index(buffer.startIndex, offsetBy: 5))
        let length = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        if Int(length) > Proto.maxPayload { throw ParseError.payloadTooLarge }
        let total = 5 + Int(length)
        guard buffer.count >= total else { return nil }
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 5)
        let payloadEnd = buffer.index(buffer.startIndex, offsetBy: total)
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        return Frame(type: type, payload: payload)
    }
}

/// Optional Sender-side overrides for the virtual display. Any field set takes
/// precedence over what the Receiver requests in HELLO. `scale` alone (with no
/// width/height) keeps the Receiver's resolution but renders it HiDPI so macOS
/// UI isn't tiny on high-density panels.
struct DisplayOverride {
    var width: Int?
    var height: Int?
    var scale: Int?
    var fps: Int?
    var isEmpty: Bool { width == nil && height == nil && scale == nil && fps == nil }
}

// MARK: - JSON payload models

struct HelloReceiver: Codable {
    struct Screen: Codable {
        let width: Int
        let height: Int
        let scale: Int
        let fps: Int
        let bitrateMbps: Int?  // v1.2: Receiver's requested bitrate (Sender may adopt)
    }
    let version: Int
    let role: String
    let name: String?
    let deviceId: String?
    let screen: Screen
    let codecs: [String]?      // v1.3: preferred codecs, e.g. ["hevc444","hevc","h264"]
}

struct HelloSender: Codable {
    let version: Int
    let role: String
    let name: String
    let deviceId: String
}

struct HelloAck: Codable {
    struct Display: Codable {
        let width: Int   // encoded/streamed pixel width (framebuffer)
        let height: Int  // encoded/streamed pixel height (framebuffer)
        let fps: Int
        let scale: Int?  // HiDPI factor: logical points = width/scale (Receiver windowed sizing)
    }
    let version: Int
    let accepted: Bool
    let display: Display?
    let codec: String?
    let reason: String?
    let pairSecret: String?
}

struct VideoConfig: Codable {
    // Required: codec/width/height. Optional (absent = unchanged): fps/bitrateMbps.
    // Receivers must tolerate missing optional fields + unknown fields (02 §5, v1.8).
    let codec: String
    let width: Int
    let height: Int
    let fps: Int?
    let bitrateMbps: Int?
}

struct ByeMsg: Codable {
    let reason: String
}

// v1.4: connection ↔ projection decoupling
struct ProjectionState: Codable {
    let active: Bool
    let label: String?
    let sourceKind: String?  // "window" | "desktop"
}

struct ControlMsg: Codable {
    let action: String       // "bounceBack" | "stop" | ...
}

struct RelayRegister: Codable {
    let v: Int
    let role: String
    let code: String
    let pairHash: String?
    let token: String?   // v1.5: public-relay auth
}

struct RelayJoin: Codable {
    let v: Int
    let role: String
    let code: String
    let pairHash: String?
    let token: String?
}

struct RelayError: Codable {
    let reason: String
}

// v1.12 mutual pairing (docs/11 / §2). The announce payload is built inside the
// PairAnnounce client (its nested Payload); here we just decode the confirmation.
struct PairConfirmed: Codable {
    let peerDeviceId: String
    let peerName: String
}

// MARK: - VIDEO_FRAME payload builder (§4)

enum VideoFramePayload {
    /// [pts_us u64 BE][flags u8][Annex-B bytes]
    static func build(ptsUs: UInt64, isKeyframe: Bool, annexB: Data) -> Data {
        var out = Data(capacity: 9 + annexB.count)
        var pts = ptsUs.bigEndian
        withUnsafeBytes(of: &pts) { out.append(contentsOf: $0) }
        out.append(isKeyframe ? 0x01 : 0x00)
        out.append(annexB)
        return out
    }
}
