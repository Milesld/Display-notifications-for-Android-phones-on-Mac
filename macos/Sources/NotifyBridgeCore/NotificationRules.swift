import Foundation

/// How an incoming phone notification should be presented on the Mac.
///
/// This is deliberately a Mac-side preference: the phone already includes the
/// source package in every notification, so no protocol change is needed.
public enum NotificationDeliveryMode: String, Codable, CaseIterable {
    /// Show a normal banner and play the notification sound.
    case banner
    /// Keep the notification in Notification Center without a banner or sound.
    case silent
}

/// Per-source delivery rules, keyed by Android package name and falling back
/// to the app label when a package is not available.
///
/// The in-memory representation uses prefixed keys so a package and a label
/// that happen to be identical never collide.
public struct NotificationRuleSet: Codable, Equatable {
    public private(set) var modes: [String: NotificationDeliveryMode]

    public init(modes: [String: NotificationDeliveryMode] = [:]) {
        self.modes = modes
    }

    public var isEmpty: Bool { modes.isEmpty }

    /// Returns the configured mode for a notification source.
    ///
    /// Matching precedence is package first, then app label. Unknown sources
    /// keep the historical behaviour: a normal banner.
    public func mode(package: String?, app: String?) -> NotificationDeliveryMode {
        if let key = Self.packageKey(package), let mode = modes[key] {
            return mode
        }
        if let key = Self.appKey(app), let mode = modes[key] {
            return mode
        }
        return .banner
    }

    /// Stores a rule. Setting a source back to banner removes its rule, which
    /// keeps the persisted set small and makes "default" and "explicitly
    /// banner" mean the same thing.
    public mutating func setMode(_ mode: NotificationDeliveryMode, package: String?, app: String?) {
        if let key = Self.packageKey(package) {
            Self.apply(mode, key: key, to: &modes)
            return
        }
        if let key = Self.appKey(app) {
            Self.apply(mode, key: key, to: &modes)
        }
    }

    private static func apply(
        _ mode: NotificationDeliveryMode,
        key: String,
        to modes: inout [String: NotificationDeliveryMode]
    ) {
        if mode == .banner {
            modes.removeValue(forKey: key)
        } else {
            modes[key] = mode
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func packageKey(_ package: String?) -> String? {
        normalized(package).map { "pkg:\($0)" }
    }

    private static func appKey(_ app: String?) -> String? {
        normalized(app).map { "app:\($0)" }
    }
}
