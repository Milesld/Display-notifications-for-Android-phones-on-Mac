import Foundation
import Network
import Security
import NotifyBridgeCore

/// Cloud relay transport. The Mac opens an outbound TLS connection to the
/// relay, registers the channel derived from the shared relay secret, receives
/// end-to-end encrypted notification envelopes, and acknowledges them so the
/// server can drop its offline queue.
final class CloudRelayReceiver {
    var onMessage: ((WireMessage) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private(set) var statusText = "云中转：未配置"
    private(set) var isConnected = false
    private(set) var isPaired = false
    private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.notifybridge.cloud", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var started = false
    private var connection: NWConnection?
    private var buffer = Data()
    private var target: RelayTarget?
    private var secret: Data?
    private var channel = ""
    private var registered = false

    private var lastReceive = Date()
    private var reconnectWork: DispatchWorkItem?
    private var handshakeWork: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?
    private var backoffIndex = 0

    private let backoffDelays: [TimeInterval] = [2, 5, 15, 30, 60, 120]

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.reloadConfiguration()
            self.connectIfConfigured()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.closeConnection()
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.registered = false
            self.publishFlags(connected: false)
            self.setStatus("云中转：已停止")
        }
    }

    func reconnectNow() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.backoffIndex = 0
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.closeConnection()
            self.connectIfConfigured()
        }
    }

    func reload() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.closeConnection()
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.backoffIndex = 0
            self.reloadConfiguration()
            self.connectIfConfigured()
        }
    }

    private func reloadConfiguration() {
        guard NetworkSettings.cloudEnabled else {
            target = nil
            secret = nil
            channel = ""
            setStatus("云中转：未配置")
            return
        }
        guard let target = NetworkSettings.cloudTarget else {
            self.target = nil
            self.secret = nil
            setStatus("云中转：请填写中继地址")
            return
        }
        guard let secret = NetworkSettings.relaySecretData else {
            self.target = nil
            self.secret = nil
            setStatus("云中转：密钥无效")
            return
        }
        self.target = target
        self.secret = secret
        self.channel = RelayCrypto.channel(secret)
    }

    private func connectIfConfigured() {
        guard started, target != nil, secret != nil else { return }
        guard connection == nil else { return }
        connect()
    }

    // MARK: - Connection

    private func connect() {
        guard let target, secret != nil, connection == nil else { return }
        let tls = NWProtocolTLS.Options()
        target.host.withCString { hostPointer in
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, hostPointer)
        }
        if NetworkSettings.insecureTLS {
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, completion in completion(true) },
                queue
            )
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: parameters
        )
        self.connection = connection
        self.buffer.removeAll(keepingCapacity: true)
        self.registered = false
        self.lastReceive = Date()
        self.setStatus("云中转：正在连接 \(target.host):\(target.port)…")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.sendRegister()
                self.armHandshakeTimeout()
            case .waiting(let error):
                AppLogger.info("Cloud relay waiting: \(error.localizedDescription)")
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
    }

    private func sendRegister() {
        guard let secret else { return }
        let message = CloudRelayMessage(
            type: "register",
            role: "mac",
            channel: channel,
            token: RelayCrypto.token(secret),
            name: Host.current().localizedName ?? "Mac"
        )
        send(message)
    }

    private func armHandshakeTimeout() {
        handshakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connection != nil, !self.registered else { return }
            self.handleFailure("注册超时")
        }
        handshakeWork = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
    }

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
                self.handleFailure("中继已断开连接")
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    private func handle(_ payload: Data) {
        do {
            let message = try decoder.decode(CloudRelayMessage.self, from: payload)
            switch message.type {
            case "registered":
                self.handshakeWork?.cancel()
                self.handshakeWork = nil
                self.registered = true
                self.backoffIndex = 0
                self.publishFlags(connected: true)
                self.startHeartbeat()
                if message.peer == true {
                    self.setStatus("云中转：已连接，通知同步中")
                } else {
                    self.setStatus("云中转：已连接，等待手机上线")
                }
                AppLogger.info("Cloud relay registered, peer=\(message.peer == true)")
            case "message":
                handleRelayMessage(message)
            case "peer":
                if message.peer == true {
                    setStatus("云中转：已连接，通知同步中")
                } else {
                    setStatus("云中转：已连接，等待手机上线")
                }
            case "ping":
                send(CloudRelayMessage(type: "pong", time: nowMillis()))
            case "pong":
                break
            case "error":
                let reason = message.message ?? message.code ?? "中继拒绝连接"
                self.handleFailure("中继错误：\(reason)")
            default:
                break
            }
        } catch {
            AppLogger.error("Unable to decode cloud message: \(error.localizedDescription)")
        }
    }

    private func handleRelayMessage(_ message: CloudRelayMessage) {
        guard let id = message.id, let payload = message.payload, let secret else { return }
        do {
            let plaintext = try RelayCrypto.decrypt(payload, secret: secret, aad: Data(channel.utf8))
            let envelope = try decoder.decode(CloudEnvelope.self, from: Data(plaintext.utf8))
            if envelope.type == "notification", let wire = envelope.data {
                DispatchQueue.main.async { [weak self] in
                    self?.onMessage?(wire)
                }
            }
            send(CloudRelayMessage(type: "ack", id: id))
            AppLogger.info("Cloud relay delivered message \(id.prefix(8))…")
        } catch {
            // Do not ack a message we could not decrypt: the server keeps it
            // queued until the key/config is fixed, instead of losing it.
            AppLogger.error("Unable to decrypt relay message: \(error.localizedDescription)")
        }
    }

    // MARK: - Sending / heartbeat

    private func send(_ message: CloudRelayMessage) {
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
            AppLogger.error("Unable to encode cloud message: \(error.localizedDescription)")
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.registered else { return }
            if Date().timeIntervalSince(self.lastReceive) > 50 {
                self.handleFailure("中继心跳超时")
                return
            }
            self.send(CloudRelayMessage(type: "ping", time: self.nowMillis()))
        }
        timer.resume()
        heartbeat = timer
    }

    private func handleFailure(_ reason: String) {
        guard started else { return }
        lastError = reason
        closeConnection()
        registered = false
        publishFlags(connected: false)
        let delay = backoffDelays[min(backoffIndex, backoffDelays.count - 1)]
        backoffIndex = min(backoffIndex + 1, backoffDelays.count - 1)
        setStatus("云中转：\(reason)，\(Int(delay)) 秒后重试")
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connectIfConfigured()
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
    }

    private func publishFlags(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = connected
            self.isPaired = connected
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