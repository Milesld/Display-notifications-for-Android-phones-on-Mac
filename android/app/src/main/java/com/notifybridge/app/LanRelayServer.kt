package com.notifybridge.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Direct TCP server used for both LAN and Tailscale paths. The phone stays the
 * server (matching the BLE role model); the Mac connects to port 47821. The
 * server advertises itself with Bonjour so a Mac on the same Wi-Fi can find it
 * without configuration; a Tailscale address is entered manually on the Mac.
 *
 * The BLE service and its state are completely independent of this class.
 */
class LanRelayServer(
    private val context: Context,
    private val pinProvider: () -> String,
    private val notificationAccessProvider: () -> Boolean,
    private val onState: (String, Int) -> Unit
) {
    companion object {
        private const val TAG = "NotifyBridge"
        const val PORT = 47821
        const val SERVICE_TYPE = "_notifybridge._tcp"
        private const val MAX_CLIENTS = 4
        private const val MAX_HISTORY = 500
        private const val SOCKET_TIMEOUT_MS = 45_000
        private const val HEARTBEAT_INTERVAL_SECONDS = 10L
        private const val MAX_PIN_FAILURES = 5
        private const val GLOBAL_PIN_FAILURES = 10
        private const val GLOBAL_PIN_WINDOW_MS = 10 * 60 * 1000L
    }

    private data class Entry(val seq: Long, val json: String)

    private val lock = Any()
    private val clients = CopyOnWriteArrayList<Client>()
    private val history = ArrayDeque<Entry>()
    private val authFailures = HashMap<String, MutableList<Long>>()
    private val session = UUID.randomUUID().toString()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var running = false
    @Volatile private var sequence = 0L
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private var heartbeat: ScheduledExecutorService? = null
    private var broadcastExecutor: java.util.concurrent.ExecutorService? = null
    private var nsdManager: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val connectivity by lazy {
        context.getSystemService(ConnectivityManager::class.java)
    }

    fun start() {
        if (running) return
        running = true
        sequence = 0
        synchronized(lock) { history.clear() }
        try {
            val socket = ServerSocket()
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(PORT))
            socket.soTimeout = 1_000
            serverSocket = socket
        } catch (e: Exception) {
            running = false
            Log.e(TAG, "Unable to start LAN relay server", e)
            onState("局域网：端口 $PORT 被占用或无法监听", 0)
            return
        }

        acquireLocks()
        startNsd()
        registerNetworkCallback()

        heartbeat = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "nb-lan-heartbeat").apply { isDaemon = true }
        }.also { executor ->
            executor.scheduleAtFixedRate({
                try {
                    heartbeatTick()
                } catch (e: Exception) {
                    Log.w(TAG, "LAN heartbeat failed", e)
                }
            }, HEARTBEAT_INTERVAL_SECONDS, HEARTBEAT_INTERVAL_SECONDS, TimeUnit.SECONDS)
        }

        broadcastExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "nb-lan-broadcast").apply { isDaemon = true }
        }
        acceptThread = thread(name = "nb-lan-accept", isDaemon = true) {
            acceptLoop()
        }
        onState("局域网：监听中 · 端口 $PORT", 0)
        Log.i(TAG, "LAN relay server listening on port $PORT")
    }

    fun stop() {
        if (!running) return
        running = false
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing LAN server", e)
        }
        serverSocket = null
        acceptThread?.interrupt()
        acceptThread = null
        clients.forEach { it.close() }
        clients.clear()
        synchronized(authFailures) { authFailures.clear() }
        heartbeat?.shutdownNow()
        heartbeat = null
        broadcastExecutor?.shutdownNow()
        broadcastExecutor = null
        stopNsd()
        unregisterNetworkCallback()
        releaseLocks()
        onState("局域网：已停止", 0)
        Log.i(TAG, "LAN relay server stopped")
    }

    fun updatePin() {
        // Pin is read from the provider for every authentication attempt.
    }

    /**
     * Called for every notification that reaches the relay service, whether or
     * not BLE is paired. History lets a Mac that reconnects catch up; the Mac's
     * last acknowledged sequence is supplied in `auth.since`.
     */
    fun publish(json: String) {
        if (!running) return
        val entry: Entry
        synchronized(lock) {
            sequence += 1
            entry = Entry(sequence, json)
            history.addLast(entry)
            while (history.size > MAX_HISTORY) history.removeFirst()
        }
        val targets = clients.filter { it.paired && !it.closed }
        try {
            broadcastExecutor?.execute {
                targets.forEach { client -> sendNotification(client, entry) }
            } ?: targets.forEach { client -> sendNotification(client, entry) }
        } catch (e: Exception) {
            Log.w(TAG, "Unable to schedule LAN broadcast", e)
        }
    }

    private fun sendNotification(client: Client, entry: Entry) {
        val data = try {
            JSONObject(entry.json)
        } catch (e: Exception) {
            Log.w(TAG, "Ignoring malformed notification JSON", e)
            return
        }
        val message = JSONObject()
            .put("v", 2)
            .put("type", "notification")
            .put("seq", entry.seq)
            .put("data", data)
        client.send(message.toString())
    }

    private fun acceptLoop() {
        while (running) {
            val socket = try {
                serverSocket?.accept() ?: break
            } catch (e: SocketTimeoutException) {
                continue
            } catch (e: Exception) {
                if (running) Log.w(TAG, "LAN accept failed", e)
                break
            }
            try {
                socket.tcpNoDelay = true
                socket.soTimeout = SOCKET_TIMEOUT_MS
                if (clients.size >= MAX_CLIENTS) {
                    Log.w(TAG, "Too many LAN clients; rejecting connection")
                    socket.close()
                    continue
                }
                val client = Client(socket)
                clients.add(client)
                thread(name = "nb-lan-client", isDaemon = true) {
                    handleClient(client)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Unable to set up LAN client", e)
                try {
                    socket.close()
                } catch (ignored: Exception) {
                }
            }
        }
    }

    private fun handleClient(client: Client) {
        try {
            client.send(
                JSONObject()
                    .put("v", 2)
                    .put("type", "hello")
                    .put("proto", 2)
                    .put("deviceId", DeviceIdentity.bytes(context).joinToString("") {
                        String.format(Locale.US, "%02X", it.toInt() and 0xFF)
                    })
                    .put("name", NetworkPrefs.deviceName())
                    .put("session", session)
                    .toString()
            )
            while (running && !client.closed) {
                val text = TcpFrameCodec.read(client.input) ?: break
                client.lastIncoming = System.currentTimeMillis()
                handleMessage(client, text)
            }
        } catch (e: SocketTimeoutException) {
            Log.i(TAG, "LAN client timed out")
        } catch (e: Exception) {
            if (running) Log.i(TAG, "LAN client disconnected: ${e.message}")
        } finally {
            clients.remove(client)
            client.close()
            publishClientCount()
        }
    }

    private fun handleMessage(client: Client, text: String) {
        val json = try {
            JSONObject(text)
        } catch (e: Exception) {
            Log.w(TAG, "Ignoring malformed LAN message")
            return
        }
        if (json.optInt("v", 0) < 2) return
        when (json.optString("type")) {
            "auth" -> handleAuth(client, json)
            "ping" -> client.send(JSONObject().put("v", 2).put("type", "pong").put("time", System.currentTimeMillis()).toString())
            "pong" -> Unit
            "ack" -> Unit
            else -> if (client.paired) Log.d(TAG, "Ignoring unknown LAN command")
        }
    }

    private fun handleAuth(client: Client, json: JSONObject) {
        if (client.paired) return
        val address = client.socket.inetAddress?.hostAddress ?: "unknown"
        if (isRateLimited(address)) {
            client.send(
                JSONObject()
                    .put("v", 2)
                    .put("type", "auth_fail")
                    .put("reason", "rate_limited")
                    .toString()
            )
            client.close()
            return
        }
        val supplied = json.optString("pin", "")
        if (!NetCrypto.pinEquals(pinProvider(), supplied)) {
            recordFailure(address)
            client.failedAttempts += 1
            client.send(
                JSONObject()
                    .put("v", 2)
                    .put("type", "auth_fail")
                    .put("reason", "pin")
                    .put("attempts", client.failedAttempts)
                    .toString()
            )
            Log.w(TAG, "LAN pairing failed (${client.failedAttempts})")
            if (client.failedAttempts >= MAX_PIN_FAILURES) client.close()
            return
        }

        client.paired = true
        client.failedAttempts = 0
        synchronized(authFailures) { authFailures.remove(address) }
        val notifications = notificationAccessProvider()
        val head = synchronized(lock) { sequence }
        client.send(
            JSONObject()
                .put("v", 2)
                .put("type", "auth_ok")
                .put("notifications", if (notifications) "on" else "off")
                .put("head", head)
                .put("session", session)
                .toString()
        )

        val since = if (json.has("since")) json.optLong("since", -1) else -1
        val clientSession = json.optString("session", "")
        if (since >= 0 && clientSession == session) {
            val backlog = synchronized(lock) {
                history.filter { it.seq > since }
            }
            backlog.forEach { sendNotification(client, it) }
        }
        Log.i(TAG, "LAN client paired (notifications=$notifications, backlog=${if (since >= 0) "yes" else "no"})")
        publishClientCount()
    }

    private fun isRateLimited(address: String): Boolean {
        synchronized(authFailures) {
            val attempts = authFailures[address] ?: return false
            val cutoff = System.currentTimeMillis() - GLOBAL_PIN_WINDOW_MS
            attempts.removeAll { it < cutoff }
            if (attempts.isEmpty()) {
                authFailures.remove(address)
                return false
            }
            return attempts.size >= GLOBAL_PIN_FAILURES
        }
    }

    private fun recordFailure(address: String) {
        synchronized(authFailures) {
            val attempts = authFailures.getOrPut(address) { mutableListOf() }
            attempts.add(System.currentTimeMillis())
            val cutoff = System.currentTimeMillis() - GLOBAL_PIN_WINDOW_MS
            attempts.removeAll { it < cutoff }
        }
    }

    private fun publishClientCount() {
        if (!running) return
        val count = clients.count { it.paired && !it.closed }
        onState(if (count > 0) "局域网：$count 个 Mac 已连接" else "局域网：监听中 · 端口 $PORT", count)
    }

    private fun heartbeatTick() {
        val now = System.currentTimeMillis()
        clients.forEach { client ->
            if (client.closed) return@forEach
            if (now - client.lastIncoming > SOCKET_TIMEOUT_MS) {
                Log.i(TAG, "Closing stale LAN client")
                client.close()
                return@forEach
            }
            client.send(
                JSONObject()
                    .put("v", 2)
                    .put("type", "ping")
                    .put("time", now)
                    .toString()
            )
        }
    }

    // MARK: - Bonjour

    private fun startNsd() {
        try {
            val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
            nsdManager = manager
            registerNsd(manager)
        } catch (e: Exception) {
            Log.w(TAG, "Bonjour registration unavailable", e)
        }
    }

    private fun registerNsd(manager: NsdManager) {
        val id = DeviceIdentity.bytes(context).joinToString("") {
            String.format(Locale.US, "%02X", it.toInt() and 0xFF)
        }
        val info = NsdServiceInfo().apply {
            serviceName = "NotifyBridge-${id.takeLast(4)}"
            serviceType = SERVICE_TYPE
            port = PORT
            setAttribute("id", id)
            setAttribute("name", NetworkPrefs.deviceName())
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "Bonjour registered as ${serviceInfo.serviceName}")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Bonjour registration failed: $errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "Bonjour unregistered")
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Bonjour unregistration failed: $errorCode")
            }
        }
        nsdListener = listener
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to register Bonjour service", e)
        }
    }

    private fun stopNsd() {
        val manager = nsdManager ?: return
        val listener = nsdListener
        try {
            if (listener != null) manager.unregisterService(listener)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to unregister Bonjour service", e)
        }
        nsdManager = null
        nsdListener = null
    }

    private fun registerNetworkCallback() {
        try {
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    mainHandler.postDelayed({
                        if (!running) return@postDelayed
                        stopNsd()
                        val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return@postDelayed
                        nsdManager = manager
                        registerNsd(manager)
                    }, 1_500)
                }
            }
            connectivity.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (e: Exception) {
            Log.w(TAG, "Unable to watch network changes", e)
        }
    }

    private fun unregisterNetworkCallback() {
        val callback = networkCallback ?: return
        try {
            connectivity.unregisterNetworkCallback(callback)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to unregister network callback", e)
        }
        networkCallback = null
    }

    private fun acquireLocks() {
        try {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifi?.createMulticastLock("notifybridge-nsd")?.apply {
                setReferenceCounted(false)
                acquire()
            }
            wifiLock = wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "notifybridge-relay")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Unable to acquire Wi-Fi locks", e)
        }
    }

    private fun releaseLocks() {
        try {
            multicastLock?.release()
        } catch (ignored: Exception) {
        }
        multicastLock = null
        try {
            wifiLock?.release()
        } catch (ignored: Exception) {
        }
        wifiLock = null
    }

    private inner class Client(val socket: Socket) {
        val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
        val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
        private val sendLock = Any()

        @Volatile var paired = false
        @Volatile var closed = false
        @Volatile var lastIncoming = System.currentTimeMillis()
        var failedAttempts = 0

        fun send(text: String): Boolean {
            if (closed) return false
            return try {
                synchronized(sendLock) {
                    TcpFrameCodec.write(output, text)
                }
                true
            } catch (e: IOException) {
                Log.w(TAG, "LAN send failed: ${e.message}")
                close()
                false
            } catch (e: Exception) {
                Log.w(TAG, "LAN send failed", e)
                close()
                false
            }
        }

        fun close() {
            if (closed) return
            closed = true
            try {
                socket.close()
            } catch (ignored: Exception) {
            }
        }
    }
}