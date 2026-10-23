import Foundation

/// Persists the pairing PIN and last phone identity. The PIN is a low-value
/// app-level code and is stored in the app's preferences; this is not a
/// replacement for a properly paired and encrypted BLE link.
enum PairingVault {
    private static let pinKey = "NotifyBridge.pairingPIN"
    private static let knownDeviceIDKey = "NotifyBridge.knownDeviceID"
    private static let knownPeripheralKey = "NotifyBridge.knownPeripheralUUID"
    private static let autoReconnectKey = "NotifyBridge.autoReconnect"

    private static var defaults: UserDefaults { .standard }

    static func loadPin() -> String? {
        guard let pin = defaults.string(forKey: pinKey),
              pin.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
            return nil
        }
        return pin
    }

    static func savePin(_ pin: String) {
        guard pin.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else { return }
        defaults.set(pin, forKey: pinKey)
    }

    static func clearPin() {
        defaults.removeObject(forKey: pinKey)
    }

    static var knownDeviceID: String? {
        get { defaults.string(forKey: knownDeviceIDKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: knownDeviceIDKey)
            } else {
                defaults.removeObject(forKey: knownDeviceIDKey)
            }
        }
    }

    static var knownPeripheralUUID: String? {
        get { defaults.string(forKey: knownPeripheralKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: knownPeripheralKey)
            } else {
                defaults.removeObject(forKey: knownPeripheralKey)
            }
        }
    }

    static var autoReconnectEnabled: Bool {
        get {
            if defaults.object(forKey: autoReconnectKey) == nil { return true }
            return defaults.bool(forKey: autoReconnectKey)
        }
        set { defaults.set(newValue, forKey: autoReconnectKey) }
    }

    static func forget() {
        clearPin()
        knownDeviceID = nil
        knownPeripheralUUID = nil
    }
}
