import Foundation
import CryptoKit
import Security

/// Persistent pairing (protocol §5 / §10). The Sender generates a 32-byte
/// `pairSecret` (base64), persists it, and sends it in HELLO_ACK; both sides
/// keep it. On reconnect both use `pairHash = lowercase hex(SHA256(rawSecret))`
/// as the relay room, so no code re-entry is needed.
///
/// IMPORTANT (aligned with Windows): hash the base64-DECODED 32 raw bytes,
/// not the base64 string.
enum PairStore {
    private static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".netdisplay-sender")
    }
    /// Per-role secret file. "sender" is the machine's own issued secret (this
    /// machine as Sender); "receiver" is a peer-issued secret we stored when this
    /// machine acted as Receiver. Separate files so both roles can pair persistently.
    private static func file(_ slot: String) -> URL {
        dir.appendingPathComponent(slot == "sender" ? "pairSecret" : "pairSecret-\(slot)")
    }

    /// Persisted pairSecret (base64) for a slot, or nil if never paired.
    static func loadSecret(slot: String = "sender") -> String? {
        guard let s = try? String(contentsOf: file(slot), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Persist a (peer-issued) secret for a slot. Used by the Receiver role when a
    /// Sender hands down HELLO_ACK.pairSecret.
    static func saveSecret(_ b64: String, slot: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? b64.write(to: file(slot), atomically: true, encoding: .utf8)
    }

    /// Existing sender secret, or generate + persist a fresh 32-byte one (base64).
    @discardableResult
    static func ensureSecret() -> String {
        if let s = loadSecret() { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let b64 = Data(bytes).base64EncodedString()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? b64.write(to: file("sender"), atomically: true, encoding: .utf8)
        Log.info("pairing: generated new pairSecret (persistent pairing enabled next run)")
        return b64
    }

    /// pairHash = lowercase hex(SHA256(base64-decode(secret))).
    static func pairHash(fromSecret b64: String) -> String? {
        guard let raw = Data(base64Encoded: b64) else { return nil }
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    /// pairHash for a slot's persisted secret, or nil if not yet paired.
    static func currentPairHash(slot: String = "sender") -> String? {
        loadSecret(slot: slot).flatMap { pairHash(fromSecret: $0) }
    }
}
