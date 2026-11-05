package com.notifybridge.app

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * Outbound TLS client for the self-hosted cloud relay. Notifications are
 * encrypted with a key derived from the relay secret before they are handed to
 * the server; the server only sees a channel id, an auth token, message ids and
 * ciphertext.
 */
class CloudRelayClient(
    private val context: Context,
    private val onState: (String, Boolean) -> Unit
) {
    companion object {
        private const val TAG = "NotifyBridge"
        private const val MAX_PENDING = 200
    }

    private data class Pending(val id: String, val json: String, var stored: Boolean = false)

    private val lock = Any()
    private val pending = LinkedHashMap<String, Pending>()
    private val session = UUID.randomUUID().toString()
    private val sendLock = Any()

    @Volatile private var running = false
    @Volatile private var connected = false
    @Volatile private var socket: Socket? = null
    @Volatile private var output: DataOutputStream? = null
    @Volatile private var config: CloudConfig? = null
    @Volatile private var lastReceive = 0L
    @Volatile private var sequence = 0L

    private var worker: Thread? = null
    private var sender: java.util.concurrent.ExecutorService? = null
    private var heartbeat: ScheduledExecutorService? = null
    private var channel = ""

    fun start(newConfig: CloudConfig) {
        stop()
        config = newConfig
        channel = NetCrypto.channel(newConfig.secret)
        running = true
        connected = false
        lastReceive = System.currentTimeMillis()
        onState("云中转：连接中…", false)

        sender = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "nb-cloud-send").apply { isDaemon = true }
        }
        heartbeat = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "nb-cloud-heartbeat").apply { isDaemon = true }
        }.also { executor ->
            executor.scheduleAtFixedRate({
                try {
                    heartbeatTick()
                } catch (e: Exception) {
                    Log.w(TAG, "Cloud heartbeat failed", e)
                }
            }, 15, 15, TimeUnit.SECONDS)
        }

        worker = Thread({
            var attempt = 0
            while (running) {
                val cfg = config ?: break
                try {
                    runConnection(cfg)
                    attempt = 0
                } catch (e: Exception) {
                    if (running) Log.w(TAG, "Cloud relay connection ended: ${e.message}")
                } finally {
                    closeSocket()
                }
                if (!running) break
                attempt = (attempt + 1).coerceAtMost(6)
                val delay = when (attempt) {
                    1 -> 2L
                    2 -> 5L
                    3 -> 15L
                    4 -> 30L
                    5 -> 60L
                    else -> 120L
                }
                onState("云中转：$delay 秒后重试", false)
                try {
                    Thread.sleep(delay * 1000)
                } catch (e: InterruptedException) {
                    break
                }
            }
            onState("云中转：已停止", false)
        }, "nb-cloud").apply { isDaemon = true }
        worker?.start()
    }

    fun stop() {
        running = false
        closeSocket()
        heartbeat?.shutdownNow()
        heartbeat = null
        sender?.shutdownNow()
        sender = null
        worker?.interrupt()
        worker = null
        synchronized(lock) { pending.clear() }
        connected = false
        onState("云中转：未配置", false)
    }

    fun publish(json: String) {
        val cfg = config ?: return
        if (!running) return
        val data = try {
            JSONObject(json)
        } catch (e: Exception) {
            return
        }
        val seq: Long
        val id = UUID.randomUUID().toString()
        val message: JSONObject
        try {
            seq = synchronized(lock) {
                sequence += 1
                sequence
            }
            val envelope = JSONObject()
                .put("type", "notification")
                .put("seq", seq)
                .put("session", session)
                .put("data", data)
            val encrypted = NetCrypto.encrypt(
                cfg.secret,
                envelope.toString(),
                channel.toByteArray(Charsets.UTF_8)
            )
            message = JSONObject()
                .put("v", 1)
                .put("type", "deliver")
                .put("id", id)
                .put("payload", encrypted)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to encrypt cloud notification", e)
            return
        }

        synchronized(lock) {
            if (pending.size >= MAX_PENDING) {
                val oldest = pending.keys.firstOrNull()
                if (oldest != null) pending.remove(oldest)
            }
            pending[id] = Pending(id, message.toString())
        }
        if (connected) {
            try {
                sender?.execute {
                    if (!connected) return@execute
                    try {
                        sendJson(message.toString())
                    } catch (e: Exception) {
                        Log.w(TAG, "Cloud send failed; will retry", e)
                        closeSocket()
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Unable to schedule cloud send", e)
            }
        }
    }

    // MARK: - Connection

    private fun runConnection(cfg: CloudConfig) {
        val raw = Socket()
        raw.tcpNoDelay = true
        raw.connect(InetSocketAddress(cfg.target.host, cfg.target.port), 15_000)
        val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
        val ssl = factory.createSocket(raw, cfg.target.host, cfg.target.port, true) as SSLSocket
        val parameters = ssl.sslParameters
        parameters.endpointIdentificationAlgorithm = "HTTPS"
        ssl.sslParameters = parameters
        ssl.soTimeout = 0
        ssl.startHandshake()
        socket = ssl
        lastReceive = System.currentTimeMillis()
        onState("云中转：正在注册…", false)

        val input = DataInputStream(BufferedInputStream(ssl.getInputStream()))
        output = DataOutputStream(BufferedOutputStream(ssl.getOutputStream()))
        // Send through the shared send path so the heartbeat can also write.
        sendJson(
            JSONObject()
                .put("v", 1)
                .put("type", "register")
                .put("role", "phone")
                .put("channel", channel)
                .put("token", NetCrypto.token(cfg.secret))
                .put("name", NetworkPrefs.deviceName())
                .toString()
        )

        while (running) {
            val text = TcpFrameCodec.read(input) ?: break
            lastReceive = System.currentTimeMillis()
            handle(text)
        }
    }

    private fun handle(text: String) {
        val json = try {
            JSONObject(text)
        } catch (e: Exception) {
            return
        }
        when (json.optString("type")) {
            "registered" -> {
                connected = true
                lastReceive = System.currentTimeMillis()
                val peer = json.optBoolean("peer", false)
                onState(if (peer) "云中转：已连接，Mac 在线" else "云中转：已连接，等待 Mac 上线", true)
                flushPending()
            }
            "stored" -> {
                val id = json.optString("id", "")
                synchronized(lock) { pending[id]?.stored = true }
            }
            "delivered" -> {
                val id = json.optString("id", "")
                synchronized(lock) { pending.remove(id) }
            }
            "message" -> handleIncoming(json)
            "peer" -> {
                val peer = json.optBoolean("peer", false)
                onState(if (peer) "云中转：已连接，Mac 在线" else "云中转：已连接，等待 Mac 上线", true)
            }
            "ping" -> sendJson(JSONObject().put("v", 1).put("type", "pong").put("time", System.currentTimeMillis()).toString())
            "pong" -> Unit
            "error" -> {
                val reason = json.optString("message", json.optString("code", "中继错误"))
                onState("云中转：$reason", false)
                throw IllegalStateException(reason)
            }
        }
    }

    private fun handleIncoming(json: JSONObject) {
        val cfg = config ?: return
        val payload = json.optString("payload", "")
        if (payload.isEmpty()) return
        val plaintext = NetCrypto.decrypt(cfg.secret, payload, channel.toByteArray(Charsets.UTF_8)) ?: return
        val envelope = try {
            JSONObject(plaintext)
        } catch (e: Exception) {
            return
        }
        // The phone has no user-facing use for incoming envelopes yet. The
        // relay's delivered/stored messages are enough for queue management.
        if (envelope.optString("type") == "ack") return
    }

    private fun flushPending() {
        val snapshot = synchronized(lock) { pending.values.toList() }
        snapshot.forEach { p ->
            if (!connected) return
            sendJson(p.json)
        }
    }

    private fun sendJson(text: String) {
        if (socket == null) throw IllegalStateException("not connected")
        synchronized(sendLock) {
            val active = output ?: throw IllegalStateException("not connected")
            TcpFrameCodec.write(active, text)
        }
    }

    private fun heartbeatTick() {
        if (!running || !connected) return
        val now = System.currentTimeMillis()
        if (now - lastReceive > 60_000) {
            Log.w(TAG, "Cloud relay heartbeat timed out")
            closeSocket()
            return
        }
        try {
            sendJson(
                JSONObject()
                    .put("v", 1)
                    .put("type", "ping")
                    .put("time", now)
                    .toString()
            )
        } catch (e: Exception) {
            closeSocket()
        }
    }

    private fun closeSocket() {
        connected = false
        val current = socket
        socket = null
        output = null
        try {
            current?.close()
        } catch (ignored: Exception) {
        }
    }
}