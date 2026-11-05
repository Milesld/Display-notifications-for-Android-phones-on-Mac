import Foundation
import NotifyBridgeCore

/// UserDefaults-backed settings for the optional network transports. The BLE
/// path remains configured by PairingVault and is unaffected by these values.
enum NetworkSettings {
    private enum Key {
        static let directEnabled = "NotifyBridge.network.directEnabled"
        static let directHost = "NotifyBridge.network.directHost"
        static let cloudEnabled = "NotifyBridge.network.cloudEnabled"
        static let relayTarget = "NotifyBridge.network.relayTarget"
        static let relaySecret = "NotifyBridge.network.relaySecret"
        static let insecureTLS = "NotifyBridge.network.insecureTLS"
        static let directSession = "NotifyBridge.network.directSession"
        static let directLastSeq = "NotifyBridge.network.directLastSeq"
    }

    private static var defaults: UserDefaults { .standard }

    static var directEnabled: Bool {
        get {
            if defaults.object(forKey: Key.directEnabled) == nil { return true }
            return defaults.bool(forKey: Key.directEnabled)
        }
        set { defaults.set(newValue, forKey: Key.directEnabled) }
    }

    static var directHost: String {
        get { defaults.string(forKey: Key.directHost) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.directHost) }
    }

    static var cloudEnabled: Bool {
        get { defaults.bool(forKey: Key.cloudEnabled) }
        set { defaults.set(newValue, forKey: Key.cloudEnabled) }
    }

    static var relayTarget: String {
        get { defaults.string(forKey: Key.relayTarget) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.relayTarget) }
    }

    static var relaySecret: String {
        get { defaults.string(forKey: Key.relaySecret) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.relaySecret) }
    }

    /// Only for a local test relay with a self-signed certificate.
    static var insecureTLS: Bool {
        get { defaults.bool(forKey: Key.insecureTLS) }
        set { defaults.set(newValue, forKey: Key.insecureTLS) }
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

    static var directTarget: RelayTarget? {
        RelayTarget.parse(directHost, defaultPort: NetworkProtocol.defaultDirectPort)
    }

    static var cloudTarget: RelayTarget? {
        RelayTarget.parse(relayTarget, defaultPort: NetworkProtocol.defaultRelayPort)
    }

    static var relaySecretData: Data? {
        RelayCrypto.decodeSecret(relaySecret)
    }

    static func forgetDirectState() {
        defaults.removeObject(forKey: Key.directSession)
        defaults.removeObject(forKey: Key.directLastSeq)
    }
}
