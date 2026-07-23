import Foundation
import CoreMedia
import CoreVideo

/// Auto transport for the receiver (mirrors the Windows `connectAuto`): start a
/// direct dial AND a relay join in parallel; **the winner is whichever reaches
/// the app-layer handshake first** (HELLO_ACK), not whichever TCP-connects first.
///
/// This matters on machines behind a proxy/VPN — especially Clash TUN, which the
/// user runs on this Mac: `connect()` to an unreachable host still "succeeds"
/// because the proxy takes the socket, so TCP-connect is a false positive. Only a
/// real HELLO_ACK proves the path reached a NetDisplay sender. The loser is torn
/// down; only the winner's frames/state reach the sink.
final class ReceiverAuto {
    private let direct: ReceiverSession?
    private let relay: ReceiverRelayClient?

    private let lock = NSLock()
    private enum Winner { case none, direct, relay }
    private var winner: Winner = .none

    var onReady: ((HelloAck.Display?, VideoCodec) -> Void)?
    var onFrame: ((CVImageBuffer, CMTime) -> Void)?
    var onProjectionState: ((Bool, String?, String?) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onClosed: (() -> Void)?

    init(direct: ReceiverSession?, relay: ReceiverRelayClient?) {
        self.direct = direct
        self.relay = relay
    }

    /// Returns true if this path just claimed the win (first to handshake).
    private func claim(_ who: Winner) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard winner == .none else { return false }
        winner = who
        Log.info("auto: \(who == .direct ? "direct" : "relay") won (handshake) — dropping the other path")
        // Tear down the loser.
        if who == .direct { relay?.stop() } else { direct?.close() }
        return true
    }

    private func isWinner(_ who: Winner) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return winner == who
    }

    func start() {
        if let d = direct {
            d.onReady = { [weak self] disp, codec in
                guard let self else { return }
                if self.claim(.direct) { self.onReady?(disp, codec) }
            }
            d.onFrame = { [weak self] img, pts in if self?.isWinner(.direct) == true { self?.onFrame?(img, pts) } }
            d.onProjectionState = { [weak self] a, l, k in if self?.isWinner(.direct) == true { self?.onProjectionState?(a, l, k) } }
            d.onResize = { [weak self] w, h in if self?.isWinner(.direct) == true { self?.onResize?(w, h) } }
            d.onClosed = { [weak self] in if self?.isWinner(.direct) == true { self?.onClosed?() } }
        }
        if let r = relay {
            r.onReady = { [weak self] disp, codec in
                guard let self else { return }
                if self.claim(.relay) { self.onReady?(disp, codec) }
            }
            r.onFrame = { [weak self] img, pts in if self?.isWinner(.relay) == true { self?.onFrame?(img, pts) } }
            r.onProjectionState = { [weak self] a, l, k in if self?.isWinner(.relay) == true { self?.onProjectionState?(a, l, k) } }
            r.onResize = { [weak self] w, h in if self?.isWinner(.relay) == true { self?.onResize?(w, h) } }
        }
        direct?.start()
        relay?.start()
    }

    func stop() {
        direct?.close()
        relay?.stop()
    }
}
