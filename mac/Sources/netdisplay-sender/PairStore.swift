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
    private static var file: URL { dir.appendingPathComponent("pairSecret") } // base64 text

    /// Persisted pairSecret (base64), or nil if never paired.
    static func loadSecret() -> String? {
        guard let s = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Existing secret, or generate + persist a fresh 32-byte one (base64).
    @discardableResult
    static func ensureSecret() -> String {
        if let s = loadSecret() { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let b64 = Data(bytes).base64EncodedString()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? b64.write(to: file, atomically: true, encoding: .utf8)
        Log.info("pairing: generated new pairSecret (persistent pairing enabled next run)")
        return b64
    }

    /// pairHash = lowercase hex(SHA256(base64-decode(secret))).
    static func pairHash(fromSecret b64: String) -> String? {
        guard let raw = Data(base64Encoded: b64) else { return nil }
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    /// pairHash for the persisted secret, or nil if not yet paired.
    static func currentPairHash() -> String? {
        loadSecret().flatMap { pairHash(fromSecret: $0) }
    }
}
