import Foundation
import Network
import NotifyBridgeCore

/// Direct TCP transport. It covers two physical paths with the same protocol:
///
/// - LAN: Bonjour discovery of `_notifybridge._tcp` on the local network.
/// - Remote: a manually configured Tailscale/MagicDNS (or other reachable)
///   host, used when Bonjour has no result.
///
/// The receiver keeps trying independently of BLE and the cloud relay. The
/// presenter deduplicates identical notifications, so more than one live path
/// is safe and the fastest one wins.
final class DirectNetworkReceiver {
    var onMessage: ((WireMessage) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private(set) var statusText = "网络：未启动"
    private(set) var isConnected = false
    private(set) var isPaired = false
    private(set) var pathName = "局域网"
    private(set) var phoneNotificationsEnabled: Bool?
    private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.notifybridge.direct", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var started = false
    private var sessionConnected = false
    private var sessionPaired = false
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private var results: Set<NWBrowser.Result> = []

    private var savedPin: String?
    private var lastSeq: Int64 = 0
    private var lastReceive = Date()
    private var handshakeWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var manualWork: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?
    private var backoffIndex = 0
    private var forceManual = false

    private let backoffDelays: [TimeInterval] = [2, 5, 15, 30, 60, 120]

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            if !NetworkSettings.directEnabled {
                self.setStatus("网络：已关闭")
                return
            }
            self.results = []
            self.savedPin = PairingVault.loadPin()
            self.lastSeq = NetworkSettings.directLastSeq
            self.setStatus("网络：正在搜索…")
            self.startBrowser()
            self.scheduleManualFallback(after: 2.5)
            if self.savedPin == nil {
                self.setStatus("网络：需要先通过蓝牙配对")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.cancelTimers()
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.manualWork?.cancel()
            self.manualWork = nil
            self.browser?.cancel()
            self.browser = nil
            self.results = []
            self.connection?.cancel()
            self.connection = nil
            self.buffer.removeAll()
            self.sessionConnected = false
            self.sessionPaired = false
            self.setStatus("网络：已停止")
            self.publishFlags(connected: false, paired: false)
        }
    }

    func reload() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelTimers()
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.manualWork?.cancel()
            self.manualWork = nil
            self.browser?.cancel()
            self.browser = nil
            self.closeConnection()
            self.results = []
            self.backoffIndex = 0
            self.forceManual = false
            self.started = true
            self.savedPin = PairingVault.loadPin()
            self.lastSeq = NetworkSettings.directLastSeq
            guard NetworkSettings.directEnabled else {
                self.setStatus("网络：已关闭")
                self.publishFlags(connected: false, paired: false)
                return
            }
            self.setStatus("网络：正在搜索…")
            self.startBrowser()
            self.scheduleManualFallback(after: 2.5)
            if self.savedPin == nil {
                self.setStatus("网络：需要先通过蓝牙配对")
            } else {
                self.attemptCandidates()
            }
        }
    }

    func reconnectNow() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.backoffIndex = 0
            self.forceManual = false
            self.closeConnection()
            self.attemptCandidates()
        }
    }

    func reloadPairing() {
        queue.async { [weak self] in
            guard let self else { return }
            self.savedPin = PairingVault.loadPin()
            if self.savedPin != nil, !self.sessionPaired, self.started {
                self.reconnectWork?.cancel()
                self.reconnectWork = nil
                self.attemptCandidates()
            }
        }
    }

    func forgetPairing() {
        queue.async { [weak self] in
            guard let self else { return }
            self.savedPin = nil
            NetworkSettings.forgetDirectState()
            self.lastSeq = 0
            self.cancelTimers()
            self.closeConnection()
            self.browser?.cancel()
            self.browser = nil
            self.setStatus("网络：需要先通过蓝牙配对")
            self.publishFlags(connected: false, paired: false)
        }
    }

    // MARK: - Bonjour discovery

    private func startBrowser() {
        guard started else { return }
        browser?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: NetworkProtocol.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !self.sessionPaired {
                    self.setStatus("网络：正在搜索局域网内的手机…")
                }
            case .failed(let error):
                self.lastError = error.localizedDescription
                AppLogger.error("Bonjour browser failed: \(error.localizedDescription)")
                if !self.sessionPaired {
                    self.setStatus("网络：局域网发现不可用，等待远程地址")
                }
            case .waiting(let error):
                AppLogger.info("Bonjour browser waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.results = results
            if self.connection == nil, self.savedPin != nil {
                self.reconnectWork?.cancel()
                self.reconnectWork = nil
                self.attemptCandidates()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func preferredResult() -> NWBrowser.Result? {
        let known = PairingVault.knownDeviceID?.uppercased()
        if let known, !known.isEmpty {
            if let match = results.first(where: { result in
                guard case let .bonjour(txt) = result.metadata,
                      let id = txt.dictionary["id"] else { return false }
                return id.uppercased() == known
            }) {
                return match
            }
        }
        return results.first
    }

    // MARK: - Connecting

    private func attemptCandidates() {
        guard started, NetworkSettings.directEnabled, connection == nil else { return }
        guard let pin = savedPin ?? PairingVault.loadPin() else {
            setStatus("网络：需要先通过蓝牙配对")
            return
        }
        savedPin = pin

        if !forceManual, let result = preferredResult() {
            connect(to: result.endpoint, path: "局域网")
            return
        }
        if let target = NetworkSettings.directTarget {
            connect(to: .hostPort(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port)!), path: "远程直连")
            return
        }
        if let result = preferredResult() {
            connect(to: result.endpoint, path: "局域网")
            return
        }

        setStatus("网络：等待手机出现在局域网，或在设置中填写远程地址")
        scheduleRetry(after: 15)
    }

    private func connect(to endpoint: NWEndpoint, path: String) {
        guard connection == nil, openedPin() != nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        self.buffer.removeAll(keepingCapacity: true)
        self.pathName = path
        self.lastReceive = Date()
        setStatus("\(path)：正在连接…")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.beginSession()
            case .waiting(let error):
                AppLogger.info("Direct connection waiting (\(path)): \(error.localizedDescription)")
            case .failed(let error):
                self.lastError = error.localizedDescription
                self.handleFailure("连接失败：\(error.localizedDescription)")
            case .cancelled:
                if self.connection === connection {
                    self.handleFailure("连接已关闭")
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(on: connection)
        armHandshakeTimeout()
    }

    private func openedPin() -> String? {
        if let savedPin, !savedPin.isEmpty { return savedPin }
        savedPin = PairingVault.loadPin()
        return savedPin
    }

    private func beginSession() {
        guard let connection, connection.state == .ready else { return }
        lastReceive = Date()
        setStatus("\(pathName)：已连接，正在配对…")
        publishFlags(connected: true, paired: false)
        sendAuth()
    }

    private func sendAuth() {
        guard let pin = openedPin() else {
            handleFailure("没有可用的配对码")
            return
        }
        var message = NetworkMessage(type: "auth", pin: pin, clientName: "notifybridge-macos")
        if lastSeq > 0, let session = NetworkSettings.directSession {
            message.since = lastSeq
            message.session = session
        }
        send(message)
    }

    private func armHandshakeTimeout() {
        handshakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connection != nil, !self.sessionPaired else { return }
            self.handleFailure("网络配对超时")
        }
        handshakeWork = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func scheduleManualFallback(after delay: TimeInterval) {
        guard NetworkSettings.directTarget != nil else { return }
        manualWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.connection == nil, self.savedPin != nil else { return }
            if self.preferredResult() == nil {
                self.attemptCandidates()
            }
        }
        manualWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Receive

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            self.lastReceive = Date()
            if let data, !data.isEmpty {
                for payload in TCPFrameCodec.append(data, to: &self.buffer) {
                    self.handle(payload)
                }
            }
            if let error {
                self.handleFailure("连接中断：\(error.localizedDescription)")
                return
            }
            if isComplete {
                self.handleFailure("手机已断开网络连接")
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    private func handle(_ payload: Data) {
        do {
            let message = try decoder.decode(NetworkMessage.self, from: payload)
            guard message.isValid else {
                AppLogger.error("Ignored invalid network message")
                return
            }
            switch message.type {
            case "hello":
                setStatus("\(pathName)：已连接 \(message.name ?? "手机")，正在配对…")
            case "auth_ok":
                handleAuthOK(message)
            case "auth_fail":
                let reason = message.reason ?? "配对码错误"
                handleFailure("网络配对失败：\(reason)")
            case "notification":
                handleNotification(message)
            case "status":
                if let detail = message.detail, !detail.isEmpty {
                    AppLogger.info("Direct phone status: \(detail)")
                }
            case "ping":
                send(NetworkMessage(type: "pong", time: nowMillis()))
            case "pong":
                break
            default:
                AppLogger.info("Unknown direct message type: \(message.type)")
            }
        } catch {
            AppLogger.error("Unable to decode direct message: \(error.localizedDescription)")
        }
    }

    private func handleAuthOK(_ message: NetworkMessage) {
        let previousSession = NetworkSettings.directSession
        if let session = message.session {
            if session != previousSession {
                NetworkSettings.directSession = session
                lastSeq = message.head ?? 0
                NetworkSettings.directLastSeq = lastSeq
                AppLogger.info("Direct session changed; starting from head \(lastSeq)")
            } else if lastSeq == 0, let head = message.head {
                lastSeq = head
                NetworkSettings.directLastSeq = head
            }
        }
        handshakeWork?.cancel()
        handshakeWork = nil
        backoffIndex = 0
        forceManual = false
        sessionConnected = true
        sessionPaired = true
        publishFlags(connected: true, paired: true)
        startHeartbeat()

        let notificationsOff = message.notifications == "off"
        DispatchQueue.main.async { [weak self] in
            self?.phoneNotificationsEnabled = !notificationsOff
        }
        if notificationsOff {
            setStatus("\(pathName)：已连接，但手机通知访问未开启")
        } else {
            setStatus("\(pathName)：已连接，通知同步中")
        }
        AppLogger.info("Direct network paired via \(pathName), head=\(message.head ?? 0)")
    }

    private func handleNotification(_ message: NetworkMessage) {
        guard let wire = message.data else {
            AppLogger.error("Notification message without data")
            return
        }
        let seq = message.seq ?? 0
        if seq == 0 || seq > lastSeq {
            if seq > lastSeq {
                lastSeq = seq
                NetworkSettings.directLastSeq = seq
            }
            DispatchQueue.main.async { [weak self] in
                self?.onMessage?(wire)
            }
        }
        if seq > 0 {
            send(NetworkMessage(type: "ack", seq: seq))
        }
    }

    // MARK: - Sending / heartbeat

    private func send(_ message: NetworkMessage) {
        guard let connection, connection.state == .ready else { return }
        do {
            let payload = try encoder.encode(message)
            let frame = TCPFrameCodec.encode(payload)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.queue.async {
                    self.handleFailure("发送失败：\(error.localizedDescription)")
                }
            })
        } catch {
            AppLogger.error("Unable to encode direct message: \(error.localizedDescription)")
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 8, repeating: 8)
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionPaired else { return }
            if Date().timeIntervalSince(self.lastReceive) > 35 {
                self.handleFailure("网络心跳超时")
                return
            }
            self.send(NetworkMessage(type: "ping", time: self.nowMillis()))
        }
        timer.resume()
        heartbeat = timer
    }

    private func cancelTimers() {
        heartbeat?.cancel()
        heartbeat = nil
        handshakeWork?.cancel()
        handshakeWork = nil
    }

    private func handleFailure(_ reason: String) {
        guard started else { return }
        lastError = reason
        closeConnection()
        DispatchQueue.main.async { [weak self] in
            self?.phoneNotificationsEnabled = nil
        }
        sessionConnected = false
        sessionPaired = false
        publishFlags(connected: false, paired: false)
        let delay = backoffDelays[min(backoffIndex, backoffDelays.count - 1)]
        backoffIndex = min(backoffIndex + 1, backoffDelays.count - 1)
        if pathName == "远程直连" {
            forceManual = false
        } else {
            forceManual = NetworkSettings.directTarget != nil
        }
        setStatus("网络：\(reason)，\(Int(delay)) 秒后重试")
        scheduleRetry(after: delay)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.attemptCandidates()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeConnection() {
        handshakeWork?.cancel()
        handshakeWork = nil
        heartbeat?.cancel()
        heartbeat = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: true)
        sessionConnected = false
        sessionPaired = false
    }

    // MARK: - State

    private func publishFlags(connected: Bool, paired: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = connected
            self.isPaired = paired
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusText = text
            self.onStatusChange?(text)
        }
    }

    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
