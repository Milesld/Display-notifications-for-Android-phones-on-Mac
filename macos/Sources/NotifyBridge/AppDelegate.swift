import AppKit
import UserNotifications
import NotifyBridgeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let receiver = BluetoothReceiver()
    private let directReceiver = DirectNetworkReceiver()
    private let cloudReceiver = CloudRelayReceiver()
    private let presenter = NotificationPresenter()

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var deviceMenuItem: NSMenuItem!
    private var networkStatusMenuItem: NSMenuItem!
    private var reconnectNetworkMenuItem: NSMenuItem!
    private var networkSettingsMenuItem: NSMenuItem!
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

    private var devices: [String] = []
    private var statusText = "正在启动…"
    private var directStatus = "网络：未启动"
    private var cloudStatus = "云中转：未配置"
    private var notificationAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        cloudReceiver.onMessage = { [weak self] message in
            self?.handleIncoming(message)
        }
        directReceiver.onStatusChange = { [weak self] text in
            guard let self else { return }
            self.directStatus = text
            self.refreshMenu()
        }
        cloudReceiver.onStatusChange = { [weak self] text in
            guard let self else { return }
            self.cloudStatus = text
            self.refreshMenu()
        }

        refreshMenu()
        receiver.start()
        directReceiver.start()
        cloudReceiver.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoLock.cancel(reason: "应用退出")
        presenter.clearAutoLockWarning()
        receiver.stop()
        directReceiver.stop()
        cloudReceiver.stop()
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

        networkSettingsMenuItem = NSMenuItem(
            title: "网络与中继设置…",
            action: #selector(showNetworkSettings),
            keyEquivalent: ""
        )
        networkSettingsMenuItem.target = self
        menu.addItem(networkSettingsMenuItem)
        menu.addItem(.separator())

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
        networkStatusMenuItem.title = "\(directStatus) · \(cloudStatus)"

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
        reconnectNetworkMenuItem.isEnabled = NetworkSettings.directEnabled || NetworkSettings.cloudEnabled

        permissionMenuItem.title = presenter.permissionSummary
    }

    private func overallStatus() -> String {
        var paths: [String] = []
        if receiver.isPaired { paths.append("蓝牙") }
        if directReceiver.isPaired { paths.append(directReceiver.pathName) }
        if cloudReceiver.isPaired { paths.append("云中转") }
        let notificationsOff = (receiver.isPaired && receiver.phoneNotificationsEnabled == false)
            || (directReceiver.isPaired && directReceiver.phoneNotificationsEnabled == false)
        if !paths.isEmpty {
            let suffix = notificationsOff ? "（手机通知监听未就绪）" : ""
            return "已连接：\(paths.joined(separator: " + "))\(suffix)"
        }
        if receiver.isConnected || directReceiver.isConnected || cloudReceiver.isConnected {
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
        cloudReceiver.reconnectNow()
        refreshMenu()
    }

    @objc private func showNetworkSettings() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "网络与中继设置"
        alert.informativeText = "蓝牙始终保留。网络通道用于手机不在蓝牙范围时继续收通知；多条通道会同时尝试，先到的那条送达。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let width: CGFloat = 430
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 330))
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: width, height: 330))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = true

        let directCheck = NSButton(checkboxWithTitle: "启用局域网 / 远程直连（TCP 47821）", target: nil, action: nil)
        directCheck.state = NetworkSettings.directEnabled ? .on : .off

        let directLabel = NSTextField(labelWithString: "远程直连地址（Tailscale IP 或 MagicDNS，留空则只用局域网）")
        directLabel.font = .systemFont(ofSize: 11)
        directLabel.textColor = .secondaryLabelColor
        let directField = NSTextField(string: NetworkSettings.directHost)
        directField.placeholderString = "例如 100.64.0.2:47821 或 pixel.tailnet-xxxx.ts.net:47821"
        directField.widthAnchor.constraint(equalToConstant: width - 8).isActive = true

        let cloudCheck = NSButton(checkboxWithTitle: "启用云中转（需要自建中继服务器）", target: nil, action: nil)
        cloudCheck.state = NetworkSettings.cloudEnabled ? .on : .off

        let cloudLabel = NSTextField(labelWithString: "中继地址（host:port，TLS）")
        cloudLabel.font = .systemFont(ofSize: 11)
        cloudLabel.textColor = .secondaryLabelColor
        let cloudField = NSTextField(string: NetworkSettings.relayTarget)
        cloudField.placeholderString = "relay.example.com:443"
        cloudField.widthAnchor.constraint(equalToConstant: width - 8).isActive = true

        let secretLabel = NSTextField(labelWithString: "中继密钥（在手机「网络与中继设置」中生成后粘贴）")
        secretLabel.font = .systemFont(ofSize: 11)
        secretLabel.textColor = .secondaryLabelColor
        let secretField = NSTextField(string: NetworkSettings.relaySecret)
        secretField.placeholderString = "43 位 Base64URL 密钥"
        secretField.widthAnchor.constraint(equalToConstant: width - 8).isActive = true

        let hint = NSTextField(wrappingLabelWithString: "中继只转发端到端加密后的内容，看不到通知正文。Tailscale 方式不需要中继服务器，只需在手机和 Mac 上登录同一个 tailnet，然后把手机的 Tailscale 地址填到上面。查看手机地址：Tailscale 管理后台 → Machines → 手机详情，复制 100.x IP 或 MagicDNS 名称；Mac 终端也可以跑 tailscale status。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: width - 8).isActive = true

        [directCheck, directLabel, directField, cloudCheck, cloudLabel, cloudField, secretLabel, secretField, hint].forEach {
            stack.addArrangedSubview($0)
        }
        container.addSubview(stack)
        stack.frame = container.bounds
        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let targetText = cloudField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretText = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if cloudCheck.state == .on {
            guard RelayTarget.parse(targetText, defaultPort: NetworkProtocol.defaultRelayPort) != nil else {
                showAlert(title: "中继地址无效", message: "请填写 host:port，例如 relay.example.com:443。")
                return
            }
            guard RelayCrypto.decodeSecret(secretText) != nil else {
                showAlert(title: "中继密钥无效", message: "请粘贴手机上显示的 43 位密钥。")
                return
            }
        }
        let directText = directField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directText.isEmpty, RelayTarget.parse(directText, defaultPort: NetworkProtocol.defaultDirectPort) == nil {
            showAlert(title: "远程直连地址无效", message: "请填写 host:port，例如 100.64.0.2:47821。")
            return
        }

        NetworkSettings.directEnabled = directCheck.state == .on
        NetworkSettings.directHost = directText
        NetworkSettings.cloudEnabled = cloudCheck.state == .on
        NetworkSettings.relayTarget = targetText
        NetworkSettings.relaySecret = secretText
        directReceiver.reload()
        cloudReceiver.reload()
        refreshMenu()
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
        通知桥把 Android 手机的新通知转发到这台 Mac。默认走低功耗蓝牙；手机不在身边时，可以自动改用局域网、Tailscale 直连或自建云中转。

        使用方法：
        1. 在 Android 手机上打开「通知桥」，授权通知访问。
        2. 启动同步服务，记下手机上的 6 位配对码。
        3. 在 Mac 菜单栏点击通知桥图标，选择「连接手机」，输入配对码。

        自动重连与多通道：
        • 首次配对成功后，Mac 会把配对码保存在本机应用设置中，并记住这台手机。
        • 蓝牙、局域网、远程直连和云中转会同时尝试；哪条通就用哪条，重复通知会去重。
        • 手机离开蓝牙范围后，局域网/Tailscale/云中转会继续送达。
        • 「网络与中继设置」里可以填写 Tailscale 地址，或配置自建中继。
        • 手机 tailnet 地址在 Tailscale 管理后台 → Machines → 手机详情里查看；Mac 终端也可用 tailscale status。填地址时要加 :47821。
        • 手动点「断开连接」只暂停蓝牙；网络通道仍会保持。
        • 「忘记已配对手机」会删除保存的配对信息，网络直连也会停止。

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

        说明：
        • 仅支持 Android。iPhone 没有向第三方 App 开放读取系统通知的接口。
        • 默认情况下内容只在手机与 Mac 之间传输。启用云中转后，中继只转发端到端加密后的密文，看不到通知正文。
        • 局域网和 Tailscale 直连使用同一套 TCP 协议；Tailscale 本身已加密，局域网内是明文（与蓝牙一致）。
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
