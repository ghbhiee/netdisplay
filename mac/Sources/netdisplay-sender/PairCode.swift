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
/// normalize(code) = uppercase then keep [A-Z0-9]         // case-insensitive, spaces dropped
/// secret   = base64( SHA256( UTF8("netdisplay-pair:" + normalize(code)) ) )
/// pairHash = lowerhex( SHA256( base64_decode(secret) ) )   // hash the RAW bytes, not the base64 string
/// ```
/// Self-test vector (v1.11): code "K7M2QX" → secret "IgIOVj/vp7y49ft6w10/GXJnX91pkGoO9AQ8zVQzKVE="
///                                         → pairHash "bec0ed709f8fd1a53d42d5e243e6cb134a939467f50bb73a5099722e5c5ae924"
enum PairCode {
    /// Prefix is exact, no trailing space (protocol §3.7).
    private static let prefix = "netdisplay-pair:"

    /// Characters used to *generate* a code — unambiguous (no I O L 0 1).
    static let genCharset = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// Generate a fresh 6-char code from the unambiguous charset.
    static func generate() -> String {
        String((0..<6).map { _ in genCharset.randomElement()! })
    }

    /// v1.11: uppercase, keep [A-Z0-9] only — case-insensitive, grouping spaces
    /// dropped (UI may show `K7M 2QX`, derivation uses `K7M2QX`). MUST match the
    /// Windows normalize rule byte-for-byte.
    static func normalize(_ code: String) -> String {
        String(code.uppercased().unicodeScalars.filter {
            (($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57))
        })
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
        let s = secret(fromCode: "K7M2QX")
        let h = pairHash(fromCode: "K7M2QX") ?? ""
        let expectS = "IgIOVj/vp7y49ft6w10/GXJnX91pkGoO9AQ8zVQzKVE="
        let expectH = "bec0ed709f8fd1a53d42d5e243e6cb134a939467f50bb73a5099722e5c5ae924"
        let normOK = normalize("k7m2 qx") == "K7M2QX"
        let ok = (s == expectS) && (h == expectH) && normOK
        Log.info("paircode-selftest: secret=\(s) \(s == expectS ? "OK" : "MISMATCH")")
        Log.info("paircode-selftest: pairHash=\(h) \(h == expectH ? "OK" : "MISMATCH")")
        Log.info("paircode-selftest: normalize(\"k7m2 qx\")=\(normalize("k7m2 qx")) \(normOK ? "OK" : "MISMATCH")")
        return ok
    }
}
