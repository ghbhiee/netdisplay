import Foundation

/// A device this machine has paired with (design: 「已配对设备」). Mirrors the
/// Windows model `{id, secret, name, alias, addr}` so both ends behave the same.
///
/// - `secret` is the stable pairing key (base64, from HELLO_ACK.pairSecret or
///   derived from the shared code via `PairCode`). The relay room is
///   `pairHash = hex(SHA256(base64decode(secret)))`.
/// - `deviceId` is the peer's stable id; unknown until the first HELLO, so a
///   freshly code-paired device is keyed by a temporary id until then.
/// - `name` is the peer-reported name (v1.10). `alias` is a local rename that
///   **wins for display** — it's this machine's user's choice, the peer can't
///   override it.
struct PairedDevice: Codable, Equatable {
    var deviceId: String          // peer's id, or "pending:<pairHash prefix>" pre-HELLO
    var secret: String            // pairing secret (base64) → pairHash room
    var name: String = ""         // peer-reported display name (HELLO.name)
    var alias: String? = nil      // local rename; wins over `name`
    var addr: String? = nil       // optional last-known LAN address (direct hint)

    /// What the UI shows: local alias > peer name > short id.
    var displayName: String {
        if let a = alias, !a.isEmpty { return a }
        if !name.isEmpty { return name }
        return String(deviceId.replacingOccurrences(of: "pending:", with: "").prefix(8))
    }

    /// Relay room key derived from the secret.
    var pairHash: String? { PairStore.pairHash(fromSecret: secret) }

    /// True until the first HELLO tells us the peer's real id.
    var isPending: Bool { deviceId.hasPrefix("pending:") }
}

/// Persistent list of paired devices + the currently-selected one. Backs both
/// the main panel「已配对设备」list and the tray menu「已配对设备」section.
enum DeviceStore {
    private static let devicesKey = "netdisplay.devices"
    private static let selectedKey = "netdisplay.selectedDevice"

    static func load() -> [PairedDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else { return [] }
        return list
    }

    static func save(_ devices: [PairedDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
        }
    }

    static var selectedId: String? {
        get { UserDefaults.standard.string(forKey: selectedKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: selectedKey) }
            else { UserDefaults.standard.removeObject(forKey: selectedKey) }
        }
    }

    /// Insert or update by `secret` (the stable key across a pending→known id
    /// transition). Returns the resulting device.
    @discardableResult
    static func upsert(_ device: PairedDevice) -> PairedDevice {
        var list = load()
        if let i = list.firstIndex(where: { $0.secret == device.secret }) {
            // preserve a user alias if the incoming update didn't carry one
            var merged = device
            if merged.alias == nil { merged.alias = list[i].alias }
            list[i] = merged
        } else {
            list.append(device)
        }
        save(list)
        return device
    }

    /// Pair from a shared 6-digit code (design: 配对弹窗). Creates/returns a
    /// device whose secret is derived from the code so both ends land in the
    /// same relay room. The peer's real id/name fill in on the first HELLO.
    @discardableResult
    static func pairFromCode(_ code: String, addr: String? = nil) -> PairedDevice {
        let secret = PairCode.secret(fromCode: code)
        let hash = PairStore.pairHash(fromSecret: secret) ?? code
        let dev = PairedDevice(deviceId: "pending:\(hash.prefix(8))", secret: secret,
                               addr: addr?.isEmpty == true ? nil : addr)
        return upsert(dev)
    }

    /// When a HELLO arrives, promote a pending device to the peer's real id/name.
    static func promote(secret: String, deviceId: String, name: String) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.secret == secret }) else { return }
        list[i].deviceId = deviceId
        if !name.isEmpty { list[i].name = name }
        save(list)
    }

    static func rename(secret: String, alias: String?) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.secret == secret }) else { return }
        list[i].alias = (alias?.isEmpty == true) ? nil : alias
        save(list)
    }

    static func remove(secret: String) {
        save(load().filter { $0.secret != secret })
        if let sel = selectedId, !load().contains(where: { $0.deviceId == sel }) { selectedId = nil }
    }
}
