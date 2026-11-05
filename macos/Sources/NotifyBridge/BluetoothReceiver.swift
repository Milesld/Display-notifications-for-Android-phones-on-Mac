import Foundation
import AppKit
import CoreBluetooth
import NotifyBridgeCore

/// Central-side receiver. It scans for the Android GATT server, subscribes to
/// the TX characteristic, sends the pairing code over RX, and decodes messages.
///
/// After the first successful pairing, the PIN and phone identity are stored so
/// the next connection can be established without user interaction. A heartbeat
/// written to RX lets the phone detect a stale link when the Mac goes away.
final class BluetoothReceiver: NSObject {
    var onStatusChange: ((String) -> Void)?
    var onDevicesChange: (([String]) -> Void)?
    var onMessage: ((WireMessage) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?

    private var discovered: [CBPeripheral] = []
    private var discoveredNames: [UUID: String] = [:]
    private var discoveredDeviceIDs: [UUID: String] = [:]

    private var reassembler = BLEFrameReassembler()
    private var outgoingFrames: [Data] = []
    private var isWriting = false
    private var outgoingSequence: UInt16 = 1

    private var activePin: String?
    private var activeDeviceID: String?
    private var savedPin: String? = PairingVault.loadPin()
    private var knownDeviceID: String? = PairingVault.knownDeviceID
    private var knownPeripheralUUID: UUID? = PairingVault.knownPeripheralUUID.flatMap { UUID(uuidString: $0) }
    private var autoReconnectSuspended = false
    private var manualDisconnectRequested = false
    private var pendingRetryPin: String?
    private var pendingRetryDeviceID: String?
    private var isRetryAttempt = false
    private var consecutiveConnectionFailures = 0
    private var reconnectCooldownUntil: Date?

    private var started = false
    private var rescanWorkItem: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var writeTimeoutTimer: Timer?
    private var connectionWatchdog: Timer?
    private var heartbeatActivity: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var isSystemSleeping = false
    private var automaticConnection = false
    private var pinRejected = false

    private(set) var statusText = "正在初始化蓝牙…"
    private(set) var isPaired = false
    /// nil = unknown (old phone), true/false = phone reported notification access.
    private(set) var phoneNotificationsEnabled: Bool?

    var autoReconnectEnabled: Bool = PairingVault.autoReconnectEnabled {
        didSet {
            guard autoReconnectEnabled != oldValue else { return }
            PairingVault.autoReconnectEnabled = autoReconnectEnabled
            if autoReconnectEnabled {
                autoReconnectSuspended = false
                if started && !isBusy {
                    scan()
                }
            }
        }
    }

    var hasSavedPairing: Bool {
        savedPin != nil
    }

    var autoReconnectActive: Bool {
        autoReconnectEnabled && !autoReconnectSuspended && savedPin != nil
    }

    var knownDeviceSummary: String? {
        if let knownDeviceID, !knownDeviceID.isEmpty {
            return "已配对手机 · \(NotifyBridgeIdentity.shortSuffix(knownDeviceID))"
        }
        if savedPin != nil {
            return "已配对手机"
        }
        return nil
    }

    var isConnected: Bool {
        peripheral?.state == .connected && txCharacteristic != nil
    }

    var isBusy: Bool {
        peripheral != nil
    }

    var activeDeviceName: String? {
        guard let peripheral else { return nil }
        return discoveredNames[peripheral.identifier] ?? peripheral.name ?? "Android 手机"
    }

    var discoveredDeviceNames: [String] {
        discovered.compactMap { discoveredNames[$0.identifier] ?? $0.name }
    }

    func start() {
        guard !started else { return }
        started = true
        savedPin = PairingVault.loadPin()
        knownDeviceID = PairingVault.knownDeviceID
        knownPeripheralUUID = PairingVault.knownPeripheralUUID.flatMap { UUID(uuidString: $0) }
        pinRejected = PairingVault.pinRejected
        registerSystemSleepObservers()
        AppLogger.info("Starting Bluetooth receiver (auto reconnect: \(autoReconnectEnabled), saved pairing: \(savedPin != nil))")
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func stop() {
        started = false
        rescanWorkItem?.cancel()
        rescanWorkItem = nil
        unregisterSystemSleepObservers()
        stopTimers()
        central?.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
        }
        cleanupConnection()
        central?.delegate = nil
        central = nil
        AppLogger.info("Stopped Bluetooth receiver")
    }

    func scan() {
        rescanWorkItem?.cancel()
        rescanWorkItem = nil
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        if let until = reconnectCooldownUntil {
            let remaining = until.timeIntervalSinceNow
            if remaining > 0 {
                let seconds = max(1, Int(ceil(remaining)))
                setStatus("连接暂时失败，\(seconds) 秒后自动重试…")
                scheduleRescan(after: remaining)
                return
            }
            reconnectCooldownUntil = nil
        }
        if central.isScanning {
            central.stopScan()
        }
        discovered.removeAll()
        discoveredNames.removeAll()
        discoveredDeviceIDs.removeAll()
        onDevicesChange?([])
        setStatus("正在搜索附近的手机…")
        central.scanForPeripherals(
            withServices: [CBUUID(string: NotifyBridgeProtocol.serviceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        AppLogger.info("Scanning for NotifyBridge service")
    }

    /// Manual connect. The caller supplies the PIN shown on the phone.
    func connectFirst(pin: String) {
        guard peripheral == nil else { return }
        guard let target = preferredDiscoveredPeripheral() else {
            setStatus("没有发现手机，请确认手机端服务已开启")
            scan()
            return
        }

        autoReconnectSuspended = false
        pendingRetryPin = nil
        pendingRetryDeviceID = nil
        isRetryAttempt = false
        consecutiveConnectionFailures = 0
        reconnectCooldownUntil = nil
        rescanWorkItem?.cancel()
        rescanWorkItem = nil
        connect(to: target, pin: pin, automatic: false)
        AppLogger.info("Manual connection to peripheral \(target.identifier.uuidString)")
    }

    func retryPairing(pin: String) {
        guard isConnected, let txCharacteristic, txCharacteristic.isNotifying else {
            setStatus("手机尚未连接")
            return
        }
        activePin = pin
        isPaired = false
        pinRejected = false
        PairingVault.pinRejected = false
        automaticConnection = false
        autoReconnectSuspended = false
        setStatus("正在重新配对…")
        sendPairing()
        armConnectionWatchdog(12, reason: "配对无响应")
    }

    func disconnect() {
        autoReconnectSuspended = true
        manualDisconnectRequested = true
        pendingRetryPin = nil
        pendingRetryDeviceID = nil
        isRetryAttempt = false
        guard let peripheral else {
            setStatus("已断开，点击「连接手机」可重连")
            return
        }
        setStatus("正在断开连接…")
        central?.cancelPeripheralConnection(peripheral)
    }

    /// Manual escape hatch for a half-open session: drop any pending request,
    /// forget the backoff and scan again without relaunching the app.
    func resetBluetoothSession() {
        guard started else { return }
        AppLogger.info("Manual BLE session reset")
        rescanWorkItem?.cancel()
        rescanWorkItem = nil
        stopConnectionWatchdog()
        pendingRetryPin = nil
        pendingRetryDeviceID = nil
        isRetryAttempt = false
        consecutiveConnectionFailures = 0
        reconnectCooldownUntil = nil
        autoReconnectSuspended = false
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
            cleanupConnection()
        }
        scan()
    }

    func forgetPairing() {
        PairingVault.forget()
        savedPin = nil
        knownDeviceID = nil
        knownPeripheralUUID = nil
        activePin = nil
        pinRejected = false
        autoReconnectSuspended = true
        pendingRetryPin = nil
        pendingRetryDeviceID = nil
        isRetryAttempt = false
        if peripheral != nil {
            manualDisconnectRequested = true
            setStatus("已忘记配对，正在断开…")
            if let peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
        } else {
            setStatus("已忘记配对，点击「连接手机」重新配对")
        }
    }

    // MARK: - Connection helpers

    private func preferredDiscoveredPeripheral() -> CBPeripheral? {
        if let knownDeviceID {
            if let match = discovered.last(where: { discoveredDeviceIDs[$0.identifier] == knownDeviceID }) {
                return match
            }
        }
        if let knownPeripheralUUID {
            if let match = discovered.last(where: { $0.identifier == knownPeripheralUUID }) {
                return match
            }
        }
        return discovered.last
    }

    private func shouldAutoConnect(peripheral: CBPeripheral, deviceID: String?) -> Bool {
        guard autoReconnectEnabled, !autoReconnectSuspended, savedPin != nil, self.peripheral == nil else {
            return false
        }
        if let knownDeviceID, !knownDeviceID.isEmpty {
            if let deviceID {
                return deviceID == knownDeviceID
            }
            if let knownPeripheralUUID {
                return peripheral.identifier == knownPeripheralUUID
            }
            return false
        }
        // Migration path for pairings created before stable IDs were advertised.
        return true
    }

    private func connect(to target: CBPeripheral, pin: String, automatic: Bool) {
        guard peripheral == nil else { return }
        activePin = pin
        activeDeviceID = discoveredDeviceIDs[target.identifier]
        automaticConnection = automatic
        isPaired = false
        manualDisconnectRequested = false
        target.delegate = self
        peripheral = target
        central?.stopScan()
        let name = discoveredNames[target.identifier] ?? target.name ?? "手机"
        setStatus(automatic ? "发现已配对手机，正在自动连接…" : "正在连接 \(name)…")
        armConnectionWatchdog(15, reason: "连接手机超时")
        central?.connect(target, options: nil)
    }

    private func attemptAutomaticConnection(to target: CBPeripheral, deviceID: String?) {
        guard let savedPin else { return }
        activeDeviceID = deviceID
        connect(to: target, pin: savedPin, automatic: true)
    }

    private func setStatus(_ text: String) {
        statusText = text
        onStatusChange?(text)
    }

    private func scheduleRescan(after delay: TimeInterval = 0.8) {
        guard started else { return }
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.peripheral == nil else { return }
            self.scan()
        }
        rescanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func backoffDelay() -> TimeInterval {
        let delays: [TimeInterval] = [2, 5, 15, 30, 60, 120, 300]
        let index = min(max(consecutiveConnectionFailures - 1, 0), delays.count - 1)
        return delays[index]
    }

    private func startCooldown(_ delay: TimeInterval, message: String) {
        reconnectCooldownUntil = Date().addingTimeInterval(delay)
        setStatus(message)
        scheduleRescan(after: delay)
    }

    // MARK: - Sleep and wake

    /// macOS powers the Bluetooth controller down for every system sleep, and
    /// this machine wakes and sleeps again every minute or so when idle.
    /// Treating each of those power transitions as "the user turned Bluetooth
    /// off" tore the session down and started a fresh scan dozens of times an
    /// hour, so a link could never survive the night.
    private func registerSystemSleepObservers() {
        guard wakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isSystemSleeping = true
            AppLogger.info("System is going to sleep; BLE session will be rebuilt on wake")
        })
        wakeObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isSystemSleeping = false
            self.resumeAfterWake()
        })
    }

    private func unregisterSystemSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach { center.removeObserver($0) }
        wakeObservers.removeAll()
    }

    /// A pending connect survives sleep in a half-open state, and failures
    /// accumulated overnight leave the reconnect cooldown at several minutes.
    /// On wake we drop the stale request, reset the backoff, and either scan or
    /// rebuild the central manager if the Bluetooth stack did not come back.
    private func resumeAfterWake() {
        guard started else { return }
        AppLogger.info("System woke; rebuilding the BLE session")
        rescanWorkItem?.cancel()
        rescanWorkItem = nil
        stopConnectionWatchdog()
        consecutiveConnectionFailures = 0
        reconnectCooldownUntil = nil
        if let peripheral {
            if peripheral.state == .connected, isPaired {
                // The link survived the nap; the heartbeat (and its write
                // timeout) will tell us if it is actually dead. Tearing it down
                // here would force a needless reconnect + re-pair.
                AppLogger.info("Keeping the existing BLE connection across wake")
                sendPing()
            } else {
                central?.cancelPeripheralConnection(peripheral)
                cleanupConnection()
            }
        }
        // The controller needs a moment to come back after wake. If it is still
        // off, the .poweredOn transition below starts the scan; rebuilding the
        // manager here would churn it on every maintenance wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.started, !self.isSystemSleeping, self.peripheral == nil else { return }
            if let central = self.central, central.state == .poweredOn {
                self.scan()
            }
        }
    }

    // MARK: - Connection watchdog

    /// CoreBluetooth never times out connect(_:options:), and service discovery
    /// can hang the same way. Without a watchdog one stuck request leaves the
    /// peripheral reference set forever: scanning stops, auto reconnect stops,
    /// and both menu entries stay disabled.
    private func armConnectionWatchdog(_ seconds: TimeInterval, reason: String) {
        stopConnectionWatchdog()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.peripheral != nil else { return }
            self.connectionWatchdog = nil
            AppLogger.error("BLE session timed out: \(reason)")
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.cleanupConnection()
            self.consecutiveConnectionFailures += 1
            let delay = self.backoffDelay()
            self.startCooldown(delay, message: "蓝牙响应超时，\(Int(delay)) 秒后自动重试…")
        }
        RunLoop.main.add(timer, forMode: .common)
        connectionWatchdog = timer
    }

    private func stopConnectionWatchdog() {
        connectionWatchdog?.invalidate()
        connectionWatchdog = nil
    }

    private func isConnectionLimitError(_ error: Error?) -> Bool {
        guard let error else { return false }
        let nsError = error as NSError
        if nsError.domain == CBErrorDomain && nsError.code == 6 { return true }
        return nsError.localizedDescription.contains("maximum number of connections")
    }

    private func cleanupConnection() {
        stopTimers()
        peripheral?.delegate = nil
        peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        reassembler.reset()
        outgoingFrames.removeAll()
        isWriting = false
        activePin = nil
        activeDeviceID = nil
        isPaired = false
        phoneNotificationsEnabled = nil
        manualDisconnectRequested = false
        automaticConnection = false
    }

    // MARK: - Pairing, heartbeat and writes

    private func sendPairing() {
        guard let pin = activePin,
              pin.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
            setStatus("配对码无效")
            return
        }
        guard isConnected,
              rxCharacteristic != nil,
              let txCharacteristic,
              txCharacteristic.isNotifying else {
            setStatus("手机尚未准备好配对")
            return
        }

        let message = WireMessage(type: "pair", pin: pin, client: "notifybridge-macos")
        enqueueControl(message)
    }

    private func startHeartbeat() {
        stopHeartbeat()
        // A menu-bar app with no window is a prime App Nap target; a throttled
        // heartbeat looks like a dead Mac to the phone, which then drops the
        // link every 30 seconds.
        if heartbeatActivity == nil {
            heartbeatActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled],
                reason: "Keep the BLE heartbeat and reconnect loop alive"
            )
        }
        sendPing()
        let timer = Timer(timeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let heartbeatActivity {
            ProcessInfo.processInfo.endActivity(heartbeatActivity)
            self.heartbeatActivity = nil
        }
    }

    private func stopTimers() {
        stopHeartbeat()
        stopConnectionWatchdog()
        writeTimeoutTimer?.invalidate()
        writeTimeoutTimer = nil
    }

    private func sendPing() {
        guard isConnected, rxCharacteristic != nil else { return }
        let message = WireMessage(type: "ping", time: Int64(Date().timeIntervalSince1970 * 1000))
        enqueueControl(message)
    }

    private func enqueueControl(_ message: WireMessage) {
        guard isConnected, rxCharacteristic != nil else { return }
        do {
            let frames = try BLEFrameCodec.encodeJSON(message, sequence: outgoingSequence)
            outgoingSequence &+= 1
            outgoingFrames.append(contentsOf: frames)
            if outgoingFrames.count > 300 {
                outgoingFrames.removeFirst(outgoingFrames.count - 300)
            }
            writeNextFrame()
        } catch {
            AppLogger.error("Unable to encode BLE command: \(error.localizedDescription)")
        }
    }

    private func writeNextFrame() {
        guard !isWriting,
              let peripheral,
              let rxCharacteristic,
              !outgoingFrames.isEmpty else {
            return
        }
        let frame = outgoingFrames.removeFirst()
        isWriting = true
        armWriteTimeout()
        peripheral.writeValue(frame, for: rxCharacteristic, type: .withResponse)
    }

    private func armWriteTimeout() {
        writeTimeoutTimer?.invalidate()
        let timer = Timer(timeInterval: 12.0, repeats: false) { [weak self] _ in
            guard let self, self.isWriting else { return }
            self.isWriting = false
            self.outgoingFrames.removeAll()
            self.setStatus("蓝牙写入超时，正在重新连接…")
            AppLogger.error("BLE write timed out")
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        writeTimeoutTimer = timer
    }

    private func handle(_ message: WireMessage) {
        guard message.isValid else {
            AppLogger.error("Ignored wire message with unsupported version/type")
            return
        }

        if message.type == "status" {
            switch message.state {
            case "waiting_for_pin":
                if !isPaired {
                    setStatus("已连接，等待配对码")
                }
            case "paired":
                isPaired = true
                stopConnectionWatchdog()
                autoReconnectSuspended = false
                pinRejected = false
                PairingVault.pinRejected = false
                if let pin = activePin {
                    savedPin = pin
                    PairingVault.savePin(pin)
                }
                let uuid = peripheral?.identifier
                let stableID = activeDeviceID ?? uuid.flatMap { discoveredDeviceIDs[$0] }
                activeDeviceID = stableID
                knownDeviceID = stableID
                PairingVault.knownDeviceID = stableID
                if let uuid {
                    knownPeripheralUUID = uuid
                    PairingVault.knownPeripheralUUID = uuid.uuidString
                }
                if heartbeatTimer == nil {
                    startHeartbeat()
                }
                let notificationsOff = message.detail?.contains("notifications=off") == true
                phoneNotificationsEnabled = !notificationsOff
                if notificationsOff {
                    setStatus("已连接并已配对，但手机通知访问未开启")
                } else if autoReconnectEnabled {
                    setStatus("已连接并已配对，自动重连已开启")
                } else {
                    setStatus("已连接并已配对")
                }
                AppLogger.info("Pairing succeeded; saved identity = \(stableID.map { NotifyBridgeIdentity.shortSuffix($0) } ?? "uuid-only")")
            case "pairing_failed":
                stopConnectionWatchdog()
                // Keep the link and the saved PIN. A single stale PIN (refreshed
                // on the phone, app data cleared, or a raced first attempt) used
                // to wipe the pairing and stop auto reconnect, leaving the Mac
                // unable to connect until it was paired by hand. Now the link
                // stays up, automatic pairing is skipped, and the menu keeps an
                // explicit "输入配对码" entry for the new code.
                isPaired = false
                phoneNotificationsEnabled = nil
                pinRejected = true
                PairingVault.pinRejected = true
                activePin = nil
                autoReconnectSuspended = false
                setStatus("配对码错误或已失效，请点「输入配对码」重新配对")
                AppLogger.error("Pairing failed; keeping the saved PIN and waiting for a manual PIN")
            default:
                if let detail = message.detail, !detail.isEmpty {
                    setStatus(detail)
                }
                AppLogger.info("Phone status: \(message.state ?? "unknown")")
            }
        }

        onMessage?(message)
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothReceiver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            AppLogger.info("Bluetooth is powered on")
            if started { scan() }
        case .poweredOff:
            if peripheral != nil {
                cleanupConnection()
            }
            if isSystemSleeping {
                setStatus("系统睡眠中，蓝牙已暂停")
                AppLogger.info("Bluetooth powered off because the system is sleeping")
            } else {
                setStatus("蓝牙已关闭，请在系统设置中打开蓝牙")
                AppLogger.error("Bluetooth is powered off")
            }
        case .unauthorized:
            if peripheral != nil {
                cleanupConnection()
            }
            setStatus("未获得蓝牙权限，请在系统设置 > 隐私与安全性 > 蓝牙中允许")
            AppLogger.error("Bluetooth permission denied")
        case .unsupported:
            setStatus("这台 Mac 不支持蓝牙低功耗")
            AppLogger.error("Bluetooth LE is unsupported")
        case .resetting:
            setStatus("蓝牙正在重置…")
        case .unknown:
            setStatus("蓝牙正在初始化；若弹出权限请求请允许")
        @unknown default:
            setStatus("蓝牙当前不可用")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil else { return }

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let deviceID = NotifyBridgeIdentity.parseDeviceID(fromManufacturerData: manufacturerData)
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String

        if let deviceID,
           let existingIndex = discovered.firstIndex(where: { discoveredDeviceIDs[$0.identifier] == deviceID }) {
            if discovered[existingIndex].identifier == peripheral.identifier {
                return
            }
            // The phone rotated its BLE address. Replace the stale
            // CBPeripheral instead of keeping a reference that can no longer
            // connect (CoreBluetooth reports "Device is invalid").
            let stale = discovered.remove(at: existingIndex)
            discoveredNames.removeValue(forKey: stale.identifier)
            discoveredDeviceIDs.removeValue(forKey: stale.identifier)
        } else if discovered.contains(where: { $0.identifier == peripheral.identifier }) {
            return
        }

        let baseName = advertisedName ?? peripheral.name ?? "Android 手机"
        let displayName: String
        if let deviceID {
            displayName = "\(baseName) · \(NotifyBridgeIdentity.shortSuffix(deviceID))"
        } else {
            displayName = baseName
        }

        discovered.append(peripheral)
        discoveredNames[peripheral.identifier] = displayName
        if let deviceID {
            discoveredDeviceIDs[peripheral.identifier] = deviceID
        }
        let manufacturerText = manufacturerData.map { data -> String in
            let hex = data.map { String(format: "%02X", $0) }.joined()
            return "\(data.count)B/\(hex)"
        } ?? "none"
        AppLogger.info("Discovered \(displayName) rssi=\(RSSI.intValue) manufacturer=\(manufacturerText)")
        onDevicesChange?(discoveredDeviceNames)

        if let pin = pendingRetryPin {
            if let expected = pendingRetryDeviceID,
               let deviceID,
               deviceID != expected {
                setStatus("正在等待刚才选择的手机重新广播…")
                return
            }
            pendingRetryPin = nil
            pendingRetryDeviceID = nil
            isRetryAttempt = true
            AppLogger.info("Retrying connection after stale peripheral")
            connect(to: peripheral, pin: pin, automatic: true)
            return
        }

        if shouldAutoConnect(peripheral: peripheral, deviceID: deviceID) {
            if RSSI.intValue < -88 {
                setStatus("发现手机，但信号较弱（\(RSSI.intValue) dBm），等待靠近…")
                scheduleRescan(after: 20)
                return
            }
            attemptAutomaticConnection(to: peripheral, deviceID: deviceID)
            return
        }

        setStatus("发现 \(displayName)，点击「连接手机」")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        AppLogger.info("Connected to peripheral")
        isRetryAttempt = false
        pendingRetryPin = nil
        pendingRetryDeviceID = nil
        consecutiveConnectionFailures = 0
        reconnectCooldownUntil = nil
        peripheral.delegate = self
        setStatus("已连接，正在发现服务…")
        armConnectionWatchdog(15, reason: "服务发现超时")
        peripheral.discoverServices([CBUUID(string: NotifyBridgeProtocol.serviceUUID)])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let description = error?.localizedDescription ?? "unknown"
        AppLogger.error("Connection failed: \(description)")
        let limitReached = isConnectionLimitError(error)
        let retryPin = activePin
        let retryDeviceID = activeDeviceID
        let canQuickRetry = !isRetryAttempt && !limitReached
        cleanupConnection()
        isRetryAttempt = false
        consecutiveConnectionFailures += 1

        if limitReached {
            pendingRetryPin = nil
            pendingRetryDeviceID = nil
            let delay: TimeInterval = consecutiveConnectionFailures > 1 ? 300 : 120
            startCooldown(
                delay,
                message: "蓝牙连接数已达上限，已暂停自动重连 \(Int(delay / 60)) 分钟"
            )
            return
        }

        if canQuickRetry, let retryPin {
            pendingRetryPin = retryPin
            pendingRetryDeviceID = retryDeviceID
            isRetryAttempt = true
            setStatus("手机蓝牙地址已刷新，正在自动重试…")
            scheduleRescan(after: 0.25)
            return
        }

        let delay = backoffDelay()
        startCooldown(delay, message: "连接失败，\(Int(delay)) 秒后自动重试…")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if let error {
            AppLogger.error("Peripheral disconnected: \(error.localizedDescription)")
        } else {
            AppLogger.info("Peripheral disconnected")
        }
        let wasManual = manualDisconnectRequested
        cleanupConnection()
        isRetryAttempt = false
        if wasManual {
            pendingRetryPin = nil
            pendingRetryDeviceID = nil
            setStatus("已断开，点击「连接手机」可重连")
        } else if autoReconnectActive {
            setStatus("手机已断开，正在等待自动重连…")
        } else {
            setStatus("手机已断开，正在重新搜索…")
        }
        scheduleRescan()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothReceiver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            AppLogger.error("Service discovery failed: \(error.localizedDescription)")
            failAndDisconnect("服务发现失败")
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: NotifyBridgeProtocol.serviceUUID)
        }) else {
            failAndDisconnect("没有找到手机端的通知服务")
            return
        }
        peripheral.discoverCharacteristics(
            [
                CBUUID(string: NotifyBridgeProtocol.txCharacteristicUUID),
                CBUUID(string: NotifyBridgeProtocol.rxCharacteristicUUID)
            ],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            AppLogger.error("Characteristic discovery failed: \(error.localizedDescription)")
            failAndDisconnect("特征发现失败")
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == CBUUID(string: NotifyBridgeProtocol.txCharacteristicUUID) {
                txCharacteristic = characteristic
            } else if characteristic.uuid == CBUUID(string: NotifyBridgeProtocol.rxCharacteristicUUID) {
                rxCharacteristic = characteristic
            }
        }

        guard let txCharacteristic, rxCharacteristic != nil else {
            failAndDisconnect("手机端服务不完整")
            return
        }

        setStatus("已连接，正在订阅通知…")
        peripheral.setNotifyValue(true, for: txCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            AppLogger.error("Notification subscription failed: \(error.localizedDescription)")
            failAndDisconnect("订阅通知失败")
            return
        }
        guard characteristic.uuid == CBUUID(string: NotifyBridgeProtocol.txCharacteristicUUID) else { return }

        if characteristic.isNotifying {
            stopConnectionWatchdog()
            startHeartbeat()
            if pinRejected && automaticConnection {
                setStatus("已连接，配对码已失效，请点「输入配对码」")
                AppLogger.info("Skipping automatic pairing because the saved PIN was rejected")
            } else {
                setStatus("已连接，正在配对…")
                sendPairing()
                // A frozen phone stack can ACK the GATT write and still never
                // answer the pairing message; without this the Mac would sit on
                // "正在配对" forever.
                armConnectionWatchdog(12, reason: "配对无响应")
            }
        } else {
            failAndDisconnect("手机没有接受通知订阅")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            AppLogger.error("Value update failed: \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == CBUUID(string: NotifyBridgeProtocol.txCharacteristicUUID),
              let data = characteristic.value else { return }
        guard let payload = reassembler.ingest(data) else { return }

        do {
            let message = try JSONDecoder().decode(WireMessage.self, from: payload)
            handle(message)
        } catch {
            AppLogger.error("Unable to decode message payload (\(payload.count) bytes)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        writeTimeoutTimer?.invalidate()
        writeTimeoutTimer = nil
        isWriting = false
        if let error {
            AppLogger.error("BLE write failed: \(error.localizedDescription)")
            outgoingFrames.removeAll()
            setStatus("与手机的连接中断，正在重新连接…")
            if let peripheral = self.peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
            return
        }
        writeNextFrame()
    }

    private func failAndDisconnect(_ reason: String) {
        AppLogger.error("Disconnecting: \(reason)")
        setStatus(reason)
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
    }
}
