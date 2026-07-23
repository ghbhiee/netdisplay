import Foundation
import CryptoKit

/// Pairing-code → relay-room derivation (protocol §3.7, v1.10).
///
/// The redesigned UX has **both machines type the same 6-digit code** (one side
/// generates it). The relay room is no longer assigned by the relay — each end
/// derives it from the code, so the algorithm is a **hard interop contract**:
/// one byte of difference sends the two ends into different rooms with both logs
/// looking normal ("same code but never matches"). Must stay byte-identical to
/// the Windows implementation (windows/src/renderer.js `pairHashHex`).
///
/// ```
/// secret   = base64( SHA256( UTF8("netdisplay-pair:" + code) ) )
/// pairHash = lowerhex( SHA256( base64_decode(secret) ) )   // hash the RAW bytes, not the base64 string
/// ```
/// Self-test vector: code "123456" → secret "8cDzqhqQD4xqw4fFnmsXG4r70M7mLv64gPR7rAmajfo="
///                                 → pairHash "a019485a2c51b7e8c2b9f3899359bcc09ea25a05dfd1e7015fb933a36429c795"
enum PairCode {
    /// Prefix is exact, no trailing space (protocol §3.7).
    private static let prefix = "netdisplay-pair:"

    /// Keep only the 6 digits — the UI may show a grouped `123 456`, but the
    /// derivation uses `123456`.
    static func normalize(_ code: String) -> String {
        String(code.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    /// `secret` = base64(SHA256("netdisplay-pair:" + code)). This is the same
    /// 32-byte secret that HELLO_ACK.pairSecret carries, so a code-derived pair
    /// and a HELLO_ACK-issued pair use the same PairStore machinery downstream.
    static func secret(fromCode code: String) -> String {
        let raw = SHA256.hash(data: Data((prefix + normalize(code)).utf8))
        return Data(raw).base64EncodedString()
    }

    /// `pairHash` = lowercase hex(SHA256(base64_decode(secret))) — the relay room
    /// key for RELAY_REGISTER/JOIN.
    static func pairHash(fromCode code: String) -> String? {
        PairStore.pairHash(fromSecret: secret(fromCode: code))
    }

    /// Verify byte-parity with the cross-end self-test vector. Returns true on match.
    static func selftest() -> Bool {
        let s = secret(fromCode: "123456")
        let h = pairHash(fromCode: "123456") ?? ""
        let expectS = "8cDzqhqQD4xqw4fFnmsXG4r70M7mLv64gPR7rAmajfo="
        let expectH = "a019485a2c51b7e8c2b9f3899359bcc09ea25a05dfd1e7015fb933a36429c795"
        let ok = (s == expectS) && (h == expectH)
        Log.info("paircode-selftest: secret=\(s) \(s == expectS ? "OK" : "MISMATCH")")
        Log.info("paircode-selftest: pairHash=\(h) \(h == expectH ? "OK" : "MISMATCH")")
        Log.info("paircode-selftest: 123456→123 456 normalize=\(normalize("123 456"))")
        return ok
    }
}
