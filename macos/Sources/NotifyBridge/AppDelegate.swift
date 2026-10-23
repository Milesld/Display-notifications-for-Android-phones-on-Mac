import AppKit
import UserNotifications
import NotifyBridgeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let receiver = BluetoothReceiver()
    private let presenter = NotificationPresenter()

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var deviceMenuItem: NSMenuItem!
    private var connectMenuItem: NSMenuItem!
    private var pairMenuItem: NSMenuItem!
    private var disconnectMenuItem: NSMenuItem!
    private var autoReconnectMenuItem: NSMenuItem!
    private var forgetMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var testMenuItem: NSMenuItem!

    private var devices: [String] = []
    private var statusText = "正在启动…"
    private var notificationAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.info("NotifyBridge launched")
        configureStatusItem()

        presenter.configure()
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
            guard let self else { return }
            if message.isNotification {
                self.presenter.deliver(message)
            }
        }

        refreshMenu()
        receiver.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        receiver.stop()
        AppLogger.info("NotifyBridge terminated")
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

        autoReconnectMenuItem = NSMenuItem(
            title: "自动重连",
            action: #selector(toggleAutoReconnect),
            keyEquivalent: ""
        )
        autoReconnectMenuItem.target = self
        menu.addItem(autoReconnectMenuItem)

        forgetMenuItem = NSMenuItem(
            title: "忘记已配对手机…",
            action: #selector(confirmForgetPairing),
            keyEquivalent: ""
        )
        forgetMenuItem.target = self
        menu.addItem(forgetMenuItem)
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

        statusMenuItem.title = "状态：\(statusText)"
        statusItem.button?.toolTip = "通知桥：\(statusText)"

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
        forgetMenuItem.isEnabled = receiver.hasSavedPairing

        permissionMenuItem.title = presenter.permissionSummary
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

    @objc private func toggleAutoReconnect() {
        receiver.autoReconnectEnabled.toggle()
        refreshMenu()
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
            refreshMenu()
        }
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
        通知桥把 Android 手机的新通知通过低功耗蓝牙转发到这台 Mac。

        使用方法：
        1. 在 Android 手机上打开「通知桥」，授权通知访问。
        2. 启动同步服务，记下手机上的 6 位配对码。
        3. 在 Mac 菜单栏点击通知桥图标，选择「连接手机」，输入配对码。

        自动重连：
        • 首次配对成功后，Mac 会把配对码保存在本机应用设置中，并记住这台手机。
        • 手机离开范围再回来、Mac 重启后，只要菜单中的「自动重连」是开启的，就会自动连接并恢复通知。
        • 手动点「断开连接」会暂停本次会话的自动重连；再点「连接手机」即可恢复。
        • 「忘记已配对手机」会删除保存的配对信息。

        通知只有通知中心、没有横幅？
        • 先确认系统设置 → 通知 → 通知桥 的样式是「横幅」或「提醒」。
        • 如果权限已经开启仍然没有横幅，检查控制中心是否启用了「专注模式/勿扰模式」。专注模式会把横幅延迟，只放进通知中心；可以把通知桥加入该专注模式的允许通知，或暂时关闭专注模式。
        • 微信、短信等能否显示具体内容，取决于手机通知本身是否包含内容。

        说明：
        • 仅支持 Android。iPhone 没有向第三方 App 开放读取系统通知的接口。
        • 所有内容只在手机与 Mac 之间传输，不经过互联网。
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
