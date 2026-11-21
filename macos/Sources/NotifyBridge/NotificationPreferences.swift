import Foundation
import NotifyBridgeCore

/// A phone app that has sent at least one notification to this Mac.
struct NotificationSource: Codable, Equatable {
    var package: String
    var app: String
    var lastSeen: TimeInterval
    var count: Int
}

/// Remembers notification sources so the settings window can list apps the
/// user has actually received notifications from. Only app labels and package
/// names are stored here; notification content never is.
enum NotificationCatalog {
    static let didChangeNotification = Notification.Name("NotifyBridge.NotificationCatalogDidChange")

    private static let defaultsKey = "NotifyBridge.notificationCatalog.v1"
    private static let maxSources = 200
    private static let lock = NSLock()

    static func record(app: String?, pkg: String?) {
        guard let package = normalize(pkg), package != "com.notifybridge.demo" else { return }
        let appName = normalize(app) ?? package
        let now = Date().timeIntervalSince1970

        lock.lock()
        var sources = load()
        if let index = sources.firstIndex(where: { $0.package == package }) {
            sources[index].app = appName
            sources[index].lastSeen = now
            sources[index].count += 1
        } else {
            sources.append(NotificationSource(package: package, app: appName, lastSeen: now, count: 1))
        }
        sources.sort { $0.lastSeen > $1.lastSeen }
        if sources.count > maxSources {
            sources.removeLast(sources.count - maxSources)
        }
        save(sources)
        lock.unlock()

        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func sources() -> [NotificationSource] {
        lock.lock()
        defer { lock.unlock() }
        return load().sorted { $0.lastSeen > $1.lastSeen }
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func load() -> [NotificationSource] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let sources = try? JSONDecoder().decode([NotificationSource].self, from: data) else {
            return []
        }
        return sources
    }

    private static func save(_ sources: [NotificationSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Persists the per-source delivery rules. The rule policy itself lives in
/// NotifyBridgeCore so it can be covered by ProtocolSelfTest.
enum NotificationPreferences {
    private static let defaultsKey = "NotifyBridge.notificationRules.v1"
    private static let lock = NSLock()

    static func mode(package: String?, app: String?) -> NotificationDeliveryMode {
        lock.lock()
        defer { lock.unlock() }
        return loadRules().mode(package: package, app: app)
    }

    static func setMode(_ mode: NotificationDeliveryMode, package: String?, app: String?) {
        lock.lock()
        defer { lock.unlock() }
        var rules = loadRules()
        rules.setMode(mode, package: package, app: app)
        saveRules(rules)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        saveRules(NotificationRuleSet())
    }

    static var hasRules: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !loadRules().isEmpty
    }

    private static func loadRules() -> NotificationRuleSet {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let rules = try? JSONDecoder().decode(NotificationRuleSet.self, from: data) else {
            return NotificationRuleSet()
        }
        return rules
    }

    private static func saveRules(_ rules: NotificationRuleSet) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
