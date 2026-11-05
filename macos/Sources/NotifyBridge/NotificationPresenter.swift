import Foundation
import UserNotifications
import NotifyBridgeCore

final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorizationGranted = false
    private(set) var permissionSummary = "通知权限：检查中…"
    var onAuthorizationChange: ((Bool) -> Void)?

    private let deliveryLock = NSLock()
    private var recentDeliveries: [String: Date] = [:]
    /// A notification can arrive over BLE, LAN and the relay almost at once.
    /// The phone's stable id plus post time is identical on every path, so it
    /// is a reliable cross-transport dedupe key while still letting a genuine
    /// update (new post time) through.
    private var deliveredKeys: [String: Date] = [:]

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        AppLogger.error("Notification authorization failed: \(error.localizedDescription)")
                    }
                    if !granted {
                        AppLogger.error("Notification authorization was not granted")
                    }
                    self.refreshAuthorization()
                }
            } else {
                self.apply(settings)
            }
        }
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            self?.apply(settings)
        }
    }

    func deliver(_ message: WireMessage) {
        guard message.isNotification else { return }

        let appName = clean(message.app) ?? "手机通知"
        let sender = clean(message.title)
        let bodyText = clean(message.text) ?? "收到一条新通知"

        let content = UNMutableNotificationContent()
        content.title = sender ?? appName
        if let sender, sender != appName {
            content.subtitle = appName
        }
        content.body = String(bodyText.prefix(2_000))
        content.sound = .default
        content.threadIdentifier = clean(message.pkg) ?? "notifybridge"
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .active
        }
        var info: [String: Any] = ["source": "notifybridge"]
        if let app = message.app { info["app"] = app }
        if let pkg = message.pkg { info["package"] = pkg }
        if let time = message.time { info["phoneTime"] = time }
        content.userInfo = info

        let fallback = "notifybridge-\(UUID().uuidString)"
        let stableID = NotifyBridgeIdentity.stableNotificationIdentifier(clean(message.id))
        let identifier = stableID.map { String($0.prefix(200)) } ?? fallback

        // A notification update can produce two callbacks milliseconds apart.
        // The same stable identifier already replaces the old card; skip the
        // second banner so it doesn't alert twice.
        let fingerprint = "\(identifier)|\(content.title)|\(content.subtitle)|\(content.body)"
        if isRecentDuplicate(fingerprint) {
            AppLogger.info("Suppressed duplicate notification")
            return
        }
        let deliveryKey = "\(identifier)|\(message.time.map(String.init) ?? "-")"
        if isAlreadyDelivered(deliveryKey) {
            AppLogger.info("Suppressed cross-transport duplicate notification")
            return
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLogger.error("Unable to deliver notification: \(error.localizedDescription)")
            }
        }
        AppLogger.info("Delivered notification from app=\(message.app ?? "?") pkg=\(message.pkg ?? "?")")
    }

    func deliverTestNotification() {
        let message = WireMessage(
            type: "notification",
            id: "notifybridge-demo-\(UUID().uuidString)",
            app: "通知桥",
            pkg: "com.notifybridge.demo",
            title: "测试通知",
            text: "如果你看到这条横幅，说明 Mac 端通知已经可以正常显示。",
            time: Int64(Date().timeIntervalSince1970 * 1000),
            category: "msg"
        )
        deliver(message)
    }

    private func apply(_ settings: UNNotificationSettings) {
        let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let alertsEnabled = settings.alertSetting == .enabled
        let centerEnabled = settings.notificationCenterSetting == .enabled
        let styleText: String
        switch settings.alertStyle {
        case .banner:
            styleText = "横幅"
        case .alert:
            styleText = "提醒"
        case .none:
            styleText = "无"
        @unknown default:
            styleText = "未知"
        }

        let summary: String
        if granted && alertsEnabled {
            summary = "通知权限：已开启（\(styleText)）"
        } else if granted && centerEnabled {
            summary = "通知权限：仅通知中心（点此设置）"
        } else if granted {
            summary = "通知权限：已静音（点此设置）"
        } else {
            summary = "通知权限：未开启（点此设置）"
        }

        let settingsDescription = "auth=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) style=\(settings.alertStyle.rawValue) center=\(settings.notificationCenterSetting.rawValue)"

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.permissionSummary != summary {
                AppLogger.info("Notification permission: \(summary) [\(settingsDescription)]")
            }
            self.permissionSummary = summary
            self.authorizationGranted = granted
            self.onAuthorizationChange?(granted)
        }
    }

    private func isAlreadyDelivered(_ key: String) -> Bool {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        let now = Date()
        deliveredKeys = deliveredKeys.filter { now.timeIntervalSince($0.value) < 24 * 60 * 60 }
        if let previous = deliveredKeys[key], now.timeIntervalSince(previous) < 24 * 60 * 60 {
            return true
        }
        deliveredKeys[key] = now
        if deliveredKeys.count > 1_000 {
            deliveredKeys = deliveredKeys.sorted { $0.value > $1.value }.prefix(500).reduce(into: [:]) { $0[$1.key] = $1.value }
        }
        return false
    }

    private func isRecentDuplicate(_ fingerprint: String) -> Bool {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        let now = Date()
        recentDeliveries = recentDeliveries.filter { now.timeIntervalSince($0.value) < 10 }
        if let previous = recentDeliveries[fingerprint], now.timeIntervalSince(previous) < 2 {
            return true
        }
        recentDeliveries[fingerprint] = now
        return false
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
