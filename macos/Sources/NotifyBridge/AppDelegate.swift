import AppKit
import UserNotifications
import NotifyBridgeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let receiver = BluetoothReceiver()
    private let directReceiver = DirectNetworkReceiver()
    private let presenter = NotificationPresenter()

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var deviceMenuItem: NSMenuItem!
    private var networkStatusMenuItem: NSMenuItem!
    private var reconnectNetworkMenuItem: NSMenuItem!
    private var connectMenuItem: NSMenuItem!
    private var pairMenuItem: NSMenuItem!
    private var disconnectMenuItem: NSMenuItem!
    private var autoReconnectMenuItem: NSMenuItem!
    private var forgetMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var testMenuItem: NSMenuItem!
    private var autoLockMenuItem: NSMenuItem!
    private var autoLockDelayMenuItem: NSMenuItem!
    private var cancelAutoLockMenuItem: NSMenuItem!
    private var testAutoLockMenuItem: NSMenuItem!

    private lazy var autoLock = AutoLockController(presenter: presenter)
    private lazy var notificationRulesWindow = NotificationRulesWindowController()

    private var devices: [String] = []
    private var statusText = "正在启动…"
    private var directStatus = "网络：未启动"
    private var notificationAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NetworkSettings.purgeLegacySettings()
        AppLogger.info("NotifyBridge launched")
        configureStatusItem()

        autoLock.onStateChange = { [weak self] in
            self?.refreshMenu()
        }
        presenter.onAutoLockCancel = { [weak self] in
            self?.autoLock.cancel(reason: "用户点击取消锁屏")
        }

        presenter.configure()
        presenter.clearAutoLockWarning()
        presenter.onAuthorizationChange = { [weak self] granted in
            guard let self else { return }
            self.notificationAllowed = granted
            self.refreshMenu()
        }
        presenter.requestAuthorization()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        receiver.onStatusChange = { [weak self] text in
            guard let self else { return }
            self.statusText = text
            if text.contains("已配对") {
                self.directReceiver.reloadPairing()
            }
            self.refreshMenu()
            if text.contains("配对码错误") {
                NSSound.beep()
            }
        }
        receiver.onDevicesChange = { [weak self] names in
            guard let self else { return }
            self.devices = names
            self.refreshMenu()
        }
        receiver.onMessage = { [weak self] message in
            self?.handleIncoming(message)
        }
        receiver.onProximityLoss = { [weak self] loss in
            self?.autoLock.handleLinkLoss(loss)
        }
        receiver.onLinkRestored = { [weak self] in
            self?.autoLock.handleLinkRestored()
        }
        receiver.onAutoLockSuppressed = { [weak self] reason in
            self?.autoLock.cancel(reason: reason)
        }
        directReceiver.onMessage = { [weak self] message in
            self?.handleIncoming(message)
        }
        directReceiver.onStatusChange = { [weak self] text in
            guard let self else { return }
            self.directStatus = text
            self.refreshMenu()
        }

        refreshMenu()
        receiver.start()
        directReceiver.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoLock.cancel(reason: "应用退出")
        presenter.clearAutoLockWarning()
        receiver.stop()
        directReceiver.stop()
        AppLogger.info("NotifyBridge terminated")
    }

    private func handleIncoming(_ message: WireMessage) {
        guard message.isNotification else { return }
        presenter.deliver(message)
    }

    // MARK: - UI

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(
                systemSymbolName: "iphone.radiowaves.left.and.right",
                accessibilityDescription: "通知桥"
            ) {
                button.image = image
                button.image?.isTemplate = true
            } else {
                button.title = "通知"
            }
            button.toolTip = "通知桥"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusMenuItem = NSMenuItem(title: "状态：正在启动…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        deviceMenuItem = NSMenuItem(title: "附近：未发现手机", action: nil, keyEquivalent: "")
        deviceMenuItem.isEnabled = false
        menu.addItem(deviceMenuItem)

        networkStatusMenuItem = NSMenuItem(title: "网络：未启动", action: nil, keyEquivalent: "")
        networkStatusMenuItem.isEnabled = false
        menu.addItem(networkStatusMenuItem)
        menu.addItem(.separator())

        connectMenuItem = NSMenuItem(
            title: "连接手机…",
            action: #selector(connectPhone),
            keyEquivalent: ""
        )
        connectMenuItem.target = self
        menu.addItem(connectMenuItem)

        pairMenuItem = NSMenuItem(
            title: "重新输入配对码…",
            action: #selector(pairAgain),
            keyEquivalent: ""
        )
        pairMenuItem.target = self
        menu.addItem(pairMenuItem)

        disconnectMenuItem = NSMenuItem(
            title: "断开连接",
            action: #selector(disconnectPhone),
            keyEquivalent: ""
        )
        disconnectMenuItem.target = self
        menu.addItem(disconnectMenuItem)

        let resetItem = NSMenuItem(
            title: "重置蓝牙连接",
            action: #selector(resetBluetoothSession),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        autoReconnectMenuItem = NSMenuItem(
            title: "自动重连",
            action: #selector(toggleAutoReconnect),
            keyEquivalent: ""
        )
        autoReconnectMenuItem.target = self
        menu.addItem(autoReconnectMenuItem)

        autoLockMenuItem = NSMenuItem(
            title: "手机离开后自动锁屏",
            action: #selector(toggleAutoLock),
            keyEquivalent: ""
        )
        autoLockMenuItem.target = self
        autoLockMenuItem.toolTip = "仅在手机已配对、自动重连开启且断开前 RSSI 很弱时触发；手机 App 被杀或蓝牙关闭不会锁屏。"
        menu.addItem(autoLockMenuItem)

        autoLockDelayMenuItem = NSMenuItem(
            title: "自动锁屏延迟",
            action: nil,
            keyEquivalent: ""
        )
        let delayMenu = NSMenu()
        delayMenu.autoenablesItems = false
        for seconds in AutoLockSettings.availableDelays {
            let item = NSMenuItem(
                title: AutoLockSettings.delayLabel(seconds),
                action: #selector(selectAutoLockDelay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(seconds)
            delayMenu.addItem(item)
        }
        autoLockDelayMenuItem.submenu = delayMenu
        menu.addItem(autoLockDelayMenuItem)

        cancelAutoLockMenuItem = NSMenuItem(
            title: "取消等待中的锁屏",
            action: #selector(cancelPendingAutoLock),
            keyEquivalent: ""
        )
        cancelAutoLockMenuItem.target = self
        menu.addItem(cancelAutoLockMenuItem)

        testAutoLockMenuItem = NSMenuItem(
            title: "测试锁屏…",
            action: #selector(testAutoLock),
            keyEquivalent: ""
        )
        testAutoLockMenuItem.target = self
        menu.addItem(testAutoLockMenuItem)
        menu.addItem(.separator())

        forgetMenuItem = NSMenuItem(
            title: "忘记已配对手机…",
            action: #selector(confirmForgetPairing),
            keyEquivalent: ""
        )
        forgetMenuItem.target = self
        menu.addItem(forgetMenuItem)

        reconnectNetworkMenuItem = NSMenuItem(
            title: "重新连接网络通道",
            action: #selector(reconnectNetworks),
            keyEquivalent: ""
        )
        reconnectNetworkMenuItem.target = self
        menu.addItem(reconnectNetworkMenuItem)

        menu.addItem(.separator())

        let notificationRulesItem = NSMenuItem(
            title: "按 App 设置通知…",
            action: #selector(showNotificationRules),
            keyEquivalent: ""
        )
        notificationRulesItem.target = self
        menu.addItem(notificationRulesItem)

        testMenuItem = NSMenuItem(
            title: "发送测试通知",
            action: #selector(sendTestNotification),
            keyEquivalent: ""
        )
        testMenuItem.target = self
        menu.addItem(testMenuItem)

        permissionMenuItem = NSMenuItem(
            title: "通知权限设置…",
            action: #selector(openNotificationSettings),
            keyEquivalent: ""
        )
        permissionMenuItem.target = self
        menu.addItem(permissionMenuItem)
        menu.addItem(.separator())

        let helpItem = NSMenuItem(
            title: "使用说明…",
            action: #selector(showHelp),
            keyEquivalent: ""
        )
        helpItem.target = self
        menu.addItem(helpItem)

        let quitItem = NSMenuItem(
            title: "退出通知桥",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refreshMenu() {
        guard let statusMenuItem else { return }

        let overall = autoLock.isPending
            ? (autoLock.pendingStatus ?? "手机已离开，准备锁屏…")
            : overallStatus()
        statusMenuItem.title = "状态：\(overall)"
        statusItem.button?.toolTip = "通知桥：\(overall)"
        networkStatusMenuItem.title = directStatus

        if devices.isEmpty {
            deviceMenuItem.title = "附近：未发现手机"
        } else {
            deviceMenuItem.title = "附近：\(devices.joined(separator: "、"))"
        }

        if devices.isEmpty {
            connectMenuItem.title = "连接手机（搜索中…）"
        } else {
            connectMenuItem.title = "连接手机「\(devices[0])」…"
        }
        connectMenuItem.isEnabled = !receiver.isBusy && !devices.isEmpty

        pairMenuItem.isEnabled = receiver.isConnected
        pairMenuItem.title = receiver.isPaired ? "重新配对…" : "输入配对码…"
        disconnectMenuItem.isEnabled = receiver.isBusy
        disconnectMenuItem.title = receiver.isBusy ? "断开连接" : "未连接"

        autoReconnectMenuItem.state = receiver.autoReconnectEnabled ? .on : .off
        autoReconnectMenuItem.title = "自动重连"
        autoReconnectMenuItem.isEnabled = true

        autoLockMenuItem.state = AutoLockSettings.enabled ? .on : .off
        autoLockMenuItem.title = receiver.autoReconnectEnabled
            ? "手机离开后自动锁屏"
            : "手机离开后自动锁屏（需自动重连）"
        // Keep the checkbox usable even when auto reconnect is off, so the
        // user can turn the feature back off; the title explains why it will
        // not fire in that state.
        autoLockMenuItem.isEnabled = true
        autoLockDelayMenuItem.title = "自动锁屏延迟（\(AutoLockSettings.delayLabel(AutoLockSettings.delay))）"
        autoLockDelayMenuItem.isEnabled = AutoLockSettings.enabled
        for item in autoLockDelayMenuItem.submenu?.items ?? [] {
            item.state = item.tag == Int(AutoLockSettings.delay) ? .on : .off
        }
        cancelAutoLockMenuItem.isEnabled = autoLock.isPending
        testAutoLockMenuItem.isEnabled = true

        forgetMenuItem.isEnabled = receiver.hasSavedPairing
        reconnectNetworkMenuItem.isEnabled = true

        permissionMenuItem.title = presenter.permissionSummary
    }

    private func overallStatus() -> String {
        var paths: [String] = []
        if receiver.isPaired { paths.append("蓝牙") }
        if directReceiver.isPaired { paths.append(directReceiver.pathName) }
        let notificationsOff = (receiver.isPaired && receiver.phoneNotificationsEnabled == false)
            || (directReceiver.isPaired && directReceiver.phoneNotificationsEnabled == false)
        if !paths.isEmpty {
            let suffix = notificationsOff ? "（手机通知监听未就绪）" : ""
            return "已连接：\(paths.joined(separator: " + "))\(suffix)"
        }
        if receiver.isConnected || directReceiver.isConnected {
            return "已连接，等待配对"
        }
        return statusText
    }

    // MARK: - Actions

    @objc private func connectPhone() {
        guard !receiver.isBusy else { return }
        guard !devices.isEmpty else {
            receiver.scan()
            showAlert(
                title: "没有发现手机",
                message: "请确认手机上的「通知桥」已经开启通知访问并启动蓝牙同步，手机就在这台 Mac 附近。"
            )
            return
        }

        guard let pin = promptForPIN() else { return }
        receiver.connectFirst(pin: pin)
    }

    @objc private func pairAgain() {
        guard receiver.isConnected else {
            showAlert(title: "手机尚未连接", message: "请先点击「连接手机」。")
            return
        }
        guard let pin = promptForPIN() else { return }
        receiver.retryPairing(pin: pin)
    }

    @objc private func disconnectPhone() {
        receiver.disconnect()
    }

    @objc private func resetBluetoothSession() {
        receiver.resetBluetoothSession()
        refreshMenu()
    }

    @objc private func toggleAutoReconnect() {
        receiver.autoReconnectEnabled.toggle()
        if !receiver.autoReconnectEnabled {
            autoLock.cancel(reason: "自动重连已关闭")
        }
        refreshMenu()
    }

    @objc private func toggleAutoLock() {
        if !AutoLockSettings.enabled {
            let waitText = AutoLockSettings.delay <= 0
                ? "当前设置为断开后立即锁屏。"
                : "当前设置为断开后等待 \(Int(AutoLockSettings.delay)) 秒，期间重连就取消。"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "启用手机离开后自动锁屏？"
            alert.informativeText = """
            只在已配对手机离开蓝牙范围、断开前信号已经很弱时才会锁屏。\(waitText)

            手机 App 被杀、手机关闭蓝牙、手机没电、Mac 睡眠、手动断开或信号抖动都不会触发。锁屏后需要输入密码或使用 Touch ID 解锁。
            """
            alert.addButton(withTitle: "启用")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else {
                refreshMenu()
                return
            }
        }

        AutoLockSettings.enabled.toggle()
        if !AutoLockSettings.enabled {
            autoLock.cancel(reason: "用户关闭自动锁屏")
        }
        autoLock.settingsDidChange()
        AppLogger.info("Auto-lock setting changed to \(AutoLockSettings.enabled)")
        refreshMenu()
    }

    @objc private func selectAutoLockDelay(_ sender: NSMenuItem) {
        let delay = TimeInterval(sender.tag)
        guard AutoLockSettings.availableDelays.contains(delay) else { return }
        AutoLockSettings.delay = delay
        autoLock.delayDidChange()
        AppLogger.info("Auto-lock delay changed to \(AutoLockSettings.delayLabel(delay))")
        refreshMenu()
    }

    @objc private func cancelPendingAutoLock() {
        autoLock.cancel(reason: "用户手动取消")
        refreshMenu()
    }

    @objc private func testAutoLock() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "测试锁屏？"
        alert.informativeText = "这会立即锁定屏幕，需要密码或 Touch ID 解锁。测试只验证锁屏调用，不会改变自动锁屏开关。"
        alert.addButton(withTitle: "立即锁屏")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = autoLock.lockNowForTesting()
        if case .failed(let reason) = result {
            showAlert(title: "锁屏失败", message: reason)
        }
    }

    @objc private func confirmForgetPairing() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "忘记已配对的手机？"
        alert.informativeText = "Mac 会删除保存的配对码和手机标识。下次连接需要重新输入手机上的 6 位配对码。"
        alert.addButton(withTitle: "忘记")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            receiver.forgetPairing()
            directReceiver.forgetPairing()
            refreshMenu()
        }
    }

    @objc private func reconnectNetworks() {
        directReceiver.reconnectNow()
        refreshMenu()
    }

    @objc private func showNotificationRules() {
        notificationRulesWindow.present()
    }

    @objc private func sendTestNotification() {
        presenter.refreshAuthorization()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            guard self.notificationAllowed else {
                let response = self.showAlert(
                    title: "通知权限未开启",
                    message: "请在系统设置中允许「通知桥」发送通知，然后重试。",
                    showCancel: true
                )
                if response {
                    self.openNotificationSettings()
                }
                return
            }
            self.presenter.deliverTestNotification()
        }
    }

    @objc private func applicationBecameActive() {
        presenter.refreshAuthorization()
    }

    @objc private func openNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
        showAlert(title: "无法打开设置", message: "请手动打开系统设置 > 通知 > 通知桥。")
    }

    @objc private func showHelp() {
        let message = """
        通知桥把 Android 手机的新通知转发到这台 Mac。默认走低功耗蓝牙；手机和 Mac 在同一 Wi-Fi 局域网时，会自动建立直连通道。

        使用方法：
        1. 在 Android 手机上打开「通知桥」，授权通知访问。
        2. 启动同步服务，记下手机上的 6 位配对码。
        3. 在 Mac 菜单栏点击通知桥图标，选择「连接手机」，输入配对码。

        自动重连与多通道：
        • 首次配对成功后，Mac 会把配对码保存在本机应用设置中，并记住这台手机。
        • 蓝牙和 Wi-Fi 局域网会同时尝试；哪条通就用哪条，重复通知会去重。
        • 手机离开蓝牙范围、但仍和 Mac 在同一 Wi-Fi 时，局域网通道会继续送达。
        • 手动点「断开连接」只暂停蓝牙；局域网通道仍会保持。
        • 「忘记已配对手机」会删除保存的配对信息，局域网通道也会停止。

        手机离开后自动锁屏（可选）：
        • 菜单勾选「手机离开后自动锁屏」，默认关闭，默认延迟 10 秒。
        • 只有已配对链路、断开前 RSSI 低于 -80 dBm，且延迟内没有重连时才锁屏。手机 App 被杀、蓝牙关闭、Mac 睡眠、手动断开不会触发。
        • 锁屏只调用屏幕锁定接口：优先 loginwindow 的 SACLockScreenImmediate，旧系统回退 CGSession -suspend。不会用系统睡眠或显示器睡眠代替；两者都不可用时直接报告锁屏失败。
        • 锁屏后 Mac 仍在运行；显示器可能按系统空闲设置熄灭，那是显示器睡眠，不是系统睡眠。
        • BLE 无法分辨是手机离开还是你带着 Mac 离开手机。锁屏前会发带「取消锁屏」按钮的通知，菜单里也能取消。

        通知只有通知中心、没有横幅？
        • 先确认系统设置 → 通知 → 通知桥 的样式是「横幅」或「提醒」。
        • 如果权限已经开启仍然没有横幅，检查控制中心是否启用了「专注模式/勿扰模式」。专注模式会把横幅延迟，只放进通知中心；可以把通知桥加入该专注模式的允许通知，或暂时关闭专注模式。
        • 微信、短信等能否显示具体内容，取决于手机通知本身是否包含内容。

        按 App 设置弹窗或静默：
        • 菜单「按 App 设置通知…」会列出收到过通知的 App，默认全部弹窗。
        • 把某个 App 改成「静默」后，它的通知仍然进入通知中心，但不弹横幅、不响铃；规则只影响之后收到的通知。
        • 静默只改变 Mac 端的显示方式，不会修改或屏蔽手机上的通知。
        • 专注模式下仍建议把通知桥加入允许通知：设为弹窗的 App 才能打断专注，设为静默的 App 不会。

        说明：
        • 仅支持 Android。iPhone 没有向第三方 App 开放读取系统通知的接口。
        • 内容只在手机与 Mac 之间直接传输，不经过任何服务器。
        • 蓝牙与 Wi-Fi 局域网都是近场链路；局域网内使用明文 TCP（与蓝牙一致），请只在可信 Wi-Fi 下使用。
        """
        showAlert(title: "通知桥", message: message)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    // MARK: - Dialogs

    private func promptForPIN() -> String? {
        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "输入手机上的配对码"
            alert.informativeText = "在 Android 手机「通知桥」首页可以看到 6 位数字。"
            alert.addButton(withTitle: "连接")
            alert.addButton(withTitle: "取消")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.placeholderString = "6 位数字"
            field.stringValue = ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return nil }

            let pin = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if pin.range(of: "^[0-9]{6}$", options: .regularExpression) != nil {
                return pin
            }
            showAlert(title: "配对码格式不对", message: "请输入手机屏幕上显示的 6 位数字。")
        }
    }

    @discardableResult
    private func showAlert(title: String, message: String, showCancel: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if showCancel {
            alert.addButton(withTitle: "打开设置")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return showCancel && response == .alertSecondButtonReturn
    }
}
