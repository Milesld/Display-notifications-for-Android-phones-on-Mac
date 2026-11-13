import Foundation

/// State captured at the moment a trusted BLE link drops. The auto-lock
/// controller uses it to distinguish "the phone walked out of range" from
/// "the phone app was killed or Bluetooth was turned off while the phone was
/// still next to the Mac".
public struct AutoLockLinkLoss: Equatable {
    public let lastRSSI: Int?
    public let rssiAge: TimeInterval
    public let wasPaired: Bool
    public let autoReconnectActive: Bool
    public let sessionDuration: TimeInterval

    public init(
        lastRSSI: Int?,
        rssiAge: TimeInterval,
        wasPaired: Bool,
        autoReconnectActive: Bool,
        sessionDuration: TimeInterval
    ) {
        self.lastRSSI = lastRSSI
        self.rssiAge = rssiAge
        self.wasPaired = wasPaired
        self.autoReconnectActive = autoReconnectActive
        self.sessionDuration = sessionDuration
    }
}

public enum AutoLockDecision: Equatable, CustomStringConvertible {
    case arm
    case notPaired
    case autoReconnectOff
    case sessionTooShort
    case rssiUnavailable
    case rssiTooStrong

    public var shouldArm: Bool {
        self == .arm
    }

    public var description: String {
        switch self {
        case .arm:
            return "weak RSSI before link loss"
        case .notPaired:
            return "link was not paired"
        case .autoReconnectOff:
            return "auto reconnect is off"
        case .sessionTooShort:
            return "session was too short"
        case .rssiUnavailable:
            return "no recent RSSI sample"
        case .rssiTooStrong:
            return "last RSSI was still strong"
        }
    }
}

/// Pure decision logic, kept out of the CoreBluetooth and AppKit code so the
/// safety rules can be exercised by ProtocolSelfTest.
public enum AutoLockPolicy {
    /// A link that drops while still at -70 dBm is almost certainly an app or
    /// stack failure, not the phone walking away. A link that is already
    /// weaker than -80 dBm when it drops is the normal range-loss case.
    public static let defaultRSSIThreshold = -80
    /// Discard an old sample: it may describe a position from before the user
    /// moved. The receiver samples every 2 seconds.
    public static let defaultMaxRSSIAge: TimeInterval = 12
    /// Do not lock after a connection that only just came up; this covers
    /// pairing/setup churn and the "connected then dropped immediately" stale
    /// link case. Keep this short: a phone flapping at the edge of range can
    /// reconnect briefly while the user is already walking away, and a longer
    /// minimum would suppress the final, real range loss.
    public static let defaultMinimumSessionDuration: TimeInterval = 3

    public static func decide(
        _ loss: AutoLockLinkLoss,
        rssiThreshold: Int = defaultRSSIThreshold,
        maxRSSIAge: TimeInterval = defaultMaxRSSIAge,
        minimumSessionDuration: TimeInterval = defaultMinimumSessionDuration
    ) -> AutoLockDecision {
        guard loss.wasPaired else { return .notPaired }
        guard loss.autoReconnectActive else { return .autoReconnectOff }
        guard loss.sessionDuration >= minimumSessionDuration else { return .sessionTooShort }
        guard let rssi = loss.lastRSSI else { return .rssiUnavailable }
        guard rssi < 0 else { return .rssiUnavailable }
        guard loss.rssiAge >= 0, loss.rssiAge <= maxRSSIAge else { return .rssiUnavailable }
        guard rssi <= rssiThreshold else { return .rssiTooStrong }
        return .arm
    }
}
