import Foundation

/// Decides when a stalled BLE session is worth rebuilding.
///
/// CoreBluetooth has no API to list or close links that the app no longer
/// tracks, and macOS can keep a link created before a system sleep alive in the
/// daemon while the app has already dropped its `CBPeripheral`. Every later
/// connect to that phone then survives only a few milliseconds, so the 15 s
/// watchdog fires again and again. Destroying and recreating the
/// `CBCentralManager` is the only way to release the link, but it must not
/// happen on every hiccup: a phone that is simply out of range would make the
/// app rebuild in a loop.
///
/// Policy: rebuild after two consecutive stalls (a connect that never reached
/// service discovery, a link that dropped within a second, or a write timeout),
/// at most once a minute.
public struct SessionRebuildPolicy {
    public static let stallThreshold = 2
    public static let minimumInterval: TimeInterval = 60

    public private(set) var consecutiveStalls = 0
    public private(set) var lastRebuildAt: Date?

    public init() {
        lastRebuildAt = nil
        consecutiveStalls = 0
    }

    /// The link made progress (connected, subscribed, paired); forget the stalls.
    public mutating func noteSuccess() {
        consecutiveStalls = 0
    }

    /// Record a failure that never reached service discovery.
    /// - Returns: true when the caller should rebuild the session now.
    public mutating func noteStall(at now: Date = Date()) -> Bool {
        consecutiveStalls += 1
        guard consecutiveStalls >= Self.stallThreshold else { return false }
        if let lastRebuildAt, now.timeIntervalSince(lastRebuildAt) < Self.minimumInterval {
            return false
        }
        return true
    }

    /// Call right after a rebuild starts.
    public mutating func noteRebuild(at now: Date = Date()) {
        lastRebuildAt = now
        consecutiveStalls = 0
    }
}
