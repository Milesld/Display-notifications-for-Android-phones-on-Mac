import Foundation
import NotifyBridgeCore

/// UserDefaults-backed settings for the optional "lock the Mac when the phone
/// leaves Bluetooth range" feature. The feature is off by default: a false
/// positive locks the user out and requires a password.
enum AutoLockSettings {
    private enum Key {
        static let enabled = "NotifyBridge.autoLock.enabled"
        static let delay = "NotifyBridge.autoLock.delay"
    }

    static let availableDelays: [TimeInterval] = [0, 5, 10, 30]
    static let defaultDelay: TimeInterval = 10
    static let rssiThreshold = AutoLockPolicy.defaultRSSIThreshold
    static let maxRSSIAge = AutoLockPolicy.defaultMaxRSSIAge
    static let minimumSessionDuration = AutoLockPolicy.defaultMinimumSessionDuration

    private static var defaults: UserDefaults { .standard }

    static var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    static var delay: TimeInterval {
        get {
            guard defaults.object(forKey: Key.delay) != nil else { return defaultDelay }
            let stored = defaults.double(forKey: Key.delay)
            return availableDelays.min(by: { abs($0 - stored) < abs($1 - stored) }) ?? defaultDelay
        }
        set { defaults.set(newValue, forKey: Key.delay) }
    }

    static func delayLabel(_ value: TimeInterval) -> String {
        value <= 0 ? "立即" : "\(Int(value)) 秒"
    }
}
