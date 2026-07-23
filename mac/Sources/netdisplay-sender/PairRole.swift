import Foundation

/// Option-A connection-role decision (docs/10-ux-model.md + 91「更新之三十四」).
/// A pair's **A 位** (listen/register — source-capable, holds the standby connection)
/// vs **B 位** (dial/join) is fixed by **deviceId UTF-8 byte order**: the
/// lexicographically smaller deviceId is A 位. Both ends compute the same answer
/// from the two deviceIds → deterministic and deadlock-free (no "both listen" or
/// "both dial"). On disconnect both fall back to this default role (spec rule 5).
enum PairRole: String {
    case a  // listen / register
    case b  // dial / join
    var isA: Bool { self == .a }

    /// Smaller deviceId (raw UTF-8 bytes, so Swift and JS agree on ASCII UUIDs) = A 位.
    static func decide(myDeviceId: String, peerDeviceId: String) -> PairRole {
        let m = Array(myDeviceId.utf8), p = Array(peerDeviceId.utf8)
        var i = 0
        while i < m.count && i < p.count {
            if m[i] != p[i] { return m[i] < p[i] ? .a : .b }
            i += 1
        }
        return m.count <= p.count ? .a : .b   // ties impossible with distinct ids
    }
}

/// Persists the peer's deviceId per role-slot (learned from the peer's HELLO),
/// so the default role can be recomputed on every reconnect. Sits alongside the
/// per-role pairSecret in `~/.netdisplay-sender/`.
enum PeerStore {
    private static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".netdisplay-sender")
    }
    private static func file(_ slot: String) -> URL {
        dir.appendingPathComponent("peerDeviceId" + (slot == "default" ? "" : "-\(slot)"))
    }
    static func save(_ id: String, slot: String = "default") {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? id.write(to: file(slot), atomically: true, encoding: .utf8)
    }
    static func load(slot: String = "default") -> String? {
        try? String(contentsOf: file(slot), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
