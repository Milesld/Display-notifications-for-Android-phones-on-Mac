import Foundation

/// UserDefaults-backed state for the Wi-Fi/LAN transport. The BLE path remains
/// configured by PairingVault and is unaffected by these values. The LAN
/// channel is always enabled; there is no user-facing switch.
enum NetworkSettings {
    private enum Key {
        static let directSession = "NotifyBridge.network.directSession"
        static let directLastSeq = "NotifyBridge.network.directLastSeq"
    }

    /// Keys written by the removed cloud-relay and manual remote-address
    /// transports. They are purged at launch so upgraded installs do not keep
    /// stale relay addresses or shared secrets on disk.
    private enum LegacyKey {
        static let directEnabled = "NotifyBridge.network.directEnabled"
        static let directHost = "NotifyBridge.network.directHost"
        static let cloudEnabled = "NotifyBridge.network.cloudEnabled"
        static let relayTarget = "NotifyBridge.network.relayTarget"
        static let relaySecret = "NotifyBridge.network.relaySecret"
        static let insecureTLS = "NotifyBridge.network.insecureTLS"

        static let all = [
            directEnabled,
            directHost,
            cloudEnabled,
            relayTarget,
            relaySecret,
            insecureTLS,
        ]
    }

    private static var defaults: UserDefaults { .standard }

    static func purgeLegacySettings() {
        for key in LegacyKey.all {
            defaults.removeObject(forKey: key)
        }
    }

    static var directSession: String? {
        get { defaults.string(forKey: Key.directSession) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.directSession)
            } else {
                defaults.removeObject(forKey: Key.directSession)
            }
        }
    }

    static var directLastSeq: Int64 {
        get { (defaults.object(forKey: Key.directLastSeq) as? NSNumber)?.int64Value ?? 0 }
        set { defaults.set(newValue, forKey: Key.directLastSeq) }
    }

    static func forgetDirectState() {
        defaults.removeObject(forKey: Key.directSession)
        defaults.removeObject(forKey: Key.directLastSeq)
    }
}
