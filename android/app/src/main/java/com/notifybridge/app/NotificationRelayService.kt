package com.notifybridge.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import org.json.JSONObject
import java.nio.charset.StandardCharsets

/**
 * Foreground service that exposes a small GATT server. The Mac connects as a
 * BLE central, subscribes to TX, and writes the pairing code to RX.
 */
class NotificationRelayService : Service() {
    companion object {
        private const val TAG = "NotifyBridge"
        const val ACTION_STOP = "com.notifybridge.app.action.STOP"
        const val ACTION_REFRESH_PIN = "com.notifybridge.app.action.REFRESH_PIN"

        private const val CHANNEL_ID = "notifybridge.relay"
        private const val NOTIFICATION_ID = 1001
        private const val MAX_QUEUE_FRAMES = 800
        private const val MAC_HEARTBEAT_TIMEOUT_MS = 30_000L
        private const val MAC_WATCHDOG_INTERVAL_MS = 4_000L
        private const val SEND_TIMEOUT_MS = 8_000L
        private const val MANUFACTURER_ID = 0xFFFF
    }

    private lateinit var notificationManager: NotificationManager
    private lateinit var bluetoothManager: BluetoothManager
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var gattServer: BluetoothGattServer? = null
    @Volatile private var txCharacteristic: BluetoothGattCharacteristic? = null
    @Volatile private var rxCharacteristic: BluetoothGattCharacteristic? = null
    @Volatile private var advertiser: BluetoothLeAdvertiser? = null
    @Volatile private var connectedDevice: BluetoothDevice? = null
    @Volatile private var isSubscribed = false
    @Volatile private var isPaired = false
    @Volatile private var isAdvertising = false
    @Volatile private var isSending = false
    @Volatile private var pin = ""
    @Volatile private var destroyed = false
    @Volatile private var lastMacContactElapsed = 0L
    private var failedAttempts = 0
    private var bluetoothReceiverRegistered = false
    private var sendTimeoutRunnable: Runnable? = null

    private val incomingReassembler = FrameReassembler()
    private val outgoingLock = Any()
    private val outgoingQueue = ArrayDeque<ByteArray>()
    private var outgoingSequence = 1

    private data class SendItem(
        val device: BluetoothDevice,
        val server: BluetoothGattServer,
        val characteristic: BluetoothGattCharacteristic,
        val frame: ByteArray
    )

    override fun onCreate() {
        super.onCreate()
        destroyed = false
        notificationManager = getSystemService(NotificationManager::class.java)
        bluetoothManager = getSystemService(BluetoothManager::class.java)
        createNotificationChannel()

        pin = PinStore.getOrCreate(this)
        RelayState.isRunning = true
        RelayState.centralConnected = false
        RelayState.paired = false
        RelayState.lastError = null
        RelayState.bluetoothState = "正在启动…"
        NotificationHub.setSink { payload -> publish(payload) }
        registerBluetoothStateReceiver()

        if (!startForegroundCompat()) {
            RelayState.isRunning = false
            stopSelf()
            return
        }
        startGattServer()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_REFRESH_PIN -> {
                pin = PinStore.refresh(this)
                failedAttempts = 0
                setBluetoothState("配对码已刷新")
                updateForegroundNotification()
            }
        }

        if (!RelayState.isRunning) {
            RelayState.isRunning = true
            startForegroundCompat()
            startGattServer()
        } else {
            updateForegroundNotification()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        destroyed = true
        RelayState.isRunning = false
        RelayState.centralConnected = false
        RelayState.paired = false
        RelayState.bluetoothState = "已停止"
        NotificationHub.setSink(null)
        stopMacWatchdog()
        disarmSendTimeout()
        unregisterBluetoothStateReceiver()
        stopAdvertising()
        try {
            gattServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing GATT server", e)
        }
        gattServer = null
        txCharacteristic = null
        rxCharacteristic = null
        connectedDevice = null
        mainHandler.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        Log.i(TAG, "Relay service stopped")
        super.onDestroy()
    }

    // MARK: - Connection liveness and Bluetooth state

    private val macWatchdog = object : Runnable {
        override fun run() {
            val device = connectedDevice ?: return
            val idle = SystemClock.elapsedRealtime() - lastMacContactElapsed
            if (idle >= MAC_HEARTBEAT_TIMEOUT_MS) {
                handleMacTimeout(device)
            } else {
                mainHandler.postDelayed(this, MAC_WATCHDOG_INTERVAL_MS)
            }
        }
    }

    private fun startMacWatchdog() {
        mainHandler.removeCallbacks(macWatchdog)
        mainHandler.postDelayed(macWatchdog, MAC_WATCHDOG_INTERVAL_MS)
    }

    private fun stopMacWatchdog() {
        mainHandler.removeCallbacks(macWatchdog)
    }

    private fun disarmSendTimeout() {
        sendTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        sendTimeoutRunnable = null
    }

    private fun armSendTimeout(device: BluetoothDevice) {
        disarmSendTimeout()
        val runnable = Runnable {
            if (!isSending) return@Runnable
            isSending = false
            synchronized(outgoingLock) { outgoingQueue.clear() }
            setBluetoothState("通知发送超时，正在恢复连接…")
            Log.w(TAG, "Notification send callback timed out")
            try {
                gattServer?.cancelConnection(device)
            } catch (e: Exception) {
                Log.w(TAG, "Unable to recover timed-out notification", e)
            }
        }
        sendTimeoutRunnable = runnable
        mainHandler.postDelayed(runnable, SEND_TIMEOUT_MS)
    }

    private fun handleMacTimeout(device: BluetoothDevice) {
        stopMacWatchdog()
        disarmSendTimeout()
        isSubscribed = false
        isPaired = false
        RelayState.centralConnected = false
        RelayState.paired = false
        setBluetoothState("Mac 连接已超时，正在重新广播…")
        Log.w(TAG, "Mac heartbeat timed out")
        try {
            gattServer?.cancelConnection(device)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to cancel timed-out connection", e)
        }
        mainHandler.postDelayed({
            if (connectedDevice == device) {
                connectedDevice = null
                isSubscribed = false
                isPaired = false
                incomingReassembler.reset()
                synchronized(outgoingLock) {
                    outgoingQueue.clear()
                    isSending = false
                }
            }
            startAdvertising()
        }, 1_200)
    }

    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_OFF -> handleBluetoothOff()
                BluetoothAdapter.STATE_ON -> handleBluetoothOn()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun registerBluetoothStateReceiver() {
        if (bluetoothReceiverRegistered) return
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(bluetoothStateReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(bluetoothStateReceiver, filter)
            }
            bluetoothReceiverRegistered = true
        } catch (e: Exception) {
            Log.w(TAG, "Unable to register Bluetooth state receiver", e)
        }
    }

    private fun unregisterBluetoothStateReceiver() {
        if (!bluetoothReceiverRegistered) return
        bluetoothReceiverRegistered = false
        try {
            unregisterReceiver(bluetoothStateReceiver)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to unregister Bluetooth state receiver", e)
        }
    }

    private fun handleBluetoothOff() {
        stopMacWatchdog()
        disarmSendTimeout()
        stopAdvertising()
        try {
            gattServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing GATT server after Bluetooth off", e)
        }
        gattServer = null
        advertiser = null
        txCharacteristic = null
        rxCharacteristic = null
        connectedDevice = null
        isSubscribed = false
        isPaired = false
        incomingReassembler.reset()
        synchronized(outgoingLock) {
            outgoingQueue.clear()
            isSending = false
        }
        RelayState.centralConnected = false
        RelayState.paired = false
        setBluetoothState("蓝牙已关闭，打开后会自动重新广播")
    }

    private fun handleBluetoothOn() {
        if (destroyed) return
        if (gattServer == null) {
            setBluetoothState("蓝牙已开启，正在重新广播…")
            startGattServer()
        }
    }

    // MARK: - Foreground notification

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.relay_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.relay_channel_description)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun startForegroundCompat(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Unable to start foreground service", e)
            RelayState.lastError = "无法启动前台服务：${e.message ?: "未知错误"}"
            false
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, NotificationRelayService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val text = when {
            isPaired -> "已连接 Mac，通知会实时同步"
            RelayState.centralConnected -> "Mac 已连接，请在手机 App 中确认配对码"
            else -> "等待 Mac 连接 · 配对码见 App"
        }

        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_stat_notify),
                    getString(R.string.stop_sync),
                    stopIntent
                ).build()
            )
            .build()
    }

    private fun updateForegroundNotification() {
        if (destroyed || !RelayState.isRunning) return
        try {
            notificationManager.notify(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            Log.w(TAG, "Unable to update foreground notification", e)
        }
    }

    // MARK: - GATT server

    private fun startGattServer() {
        if (destroyed || gattServer != null) return
        if (!hasBluetoothPermissions()) {
            fail("缺少蓝牙权限，请重新打开 App 并授权")
            return
        }

        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            fail("蓝牙未打开，请打开蓝牙后重新启动同步")
            return
        }

        try {
            advertiser = adapter.bluetoothLeAdvertiser
            if (advertiser == null) {
                fail("这台手机不支持低功耗蓝牙广播")
                return
            }

            val server = bluetoothManager.openGattServer(this, gattCallback)
            if (server == null) {
                fail("无法创建蓝牙服务")
                return
            }

            val service = BluetoothGattService(
                BleProtocol.SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY
            )
            val tx = BluetoothGattCharacteristic(
                BleProtocol.TX_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            tx.addDescriptor(
                BluetoothGattDescriptor(
                    BleProtocol.CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
            val rx = BluetoothGattCharacteristic(
                BleProtocol.RX_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            service.addCharacteristic(tx)
            service.addCharacteristic(rx)

            txCharacteristic = tx
            rxCharacteristic = rx
            gattServer = server
            setBluetoothState("正在注册蓝牙服务…")

            if (!server.addService(service)) {
                fail("注册蓝牙服务失败")
            }
        } catch (e: SecurityException) {
            fail("没有蓝牙权限：${e.message ?: ""}")
        } catch (e: Exception) {
            fail("蓝牙初始化失败：${e.message ?: "未知错误"}")
        }
    }

    private fun startAdvertising() {
        if (destroyed || connectedDevice != null || isAdvertising) return
        val adv = advertiser ?: return
        if (!hasBluetoothPermissions()) return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(BleProtocol.SERVICE_UUID))
            .setIncludeTxPowerLevel(false)
            .build()

        val scanResponse = AdvertiseData.Builder()
            .addManufacturerData(MANUFACTURER_ID, DeviceIdentity.bytes(this))
            .build()

        try {
            adv.startAdvertising(settings, data, scanResponse, advertiseCallback)
            isAdvertising = true
            setBluetoothState("正在开启蓝牙广播…")
        } catch (e: SecurityException) {
            fail("没有蓝牙广播权限")
        } catch (e: Exception) {
            fail("启动蓝牙广播失败：${e.message ?: "未知错误"}")
        }
    }

    private fun stopAdvertising() {
        val adv = advertiser
        if (isAdvertising) {
            try {
                adv?.stopAdvertising(advertiseCallback)
            } catch (e: Exception) {
                Log.w(TAG, "Unable to stop advertising", e)
            }
        }
        isAdvertising = false
    }

    private fun fail(message: String) {
        Log.e(TAG, message)
        RelayState.lastError = message
        setBluetoothState(message)
    }

    private fun setBluetoothState(text: String) {
        RelayState.bluetoothState = text
        updateForegroundNotification()
    }

    private fun hasBluetoothPermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
    }

    private fun isNotificationAccessEnabled(): Boolean {
        val enabled = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        return enabled.split(":").any { flat ->
            ComponentName.unflattenFromString(flat)?.packageName == packageName
        }
    }

    // MARK: - Advertising callback

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            if (destroyed || connectedDevice != null) {
                stopAdvertising()
                return
            }
            RelayState.centralConnected = false
            RelayState.paired = false
            setBluetoothState("等待 Mac 连接")
            Log.i(TAG, "BLE advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            val reason = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "蓝牙广播数据过大"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "蓝牙广播数量已达上限"
                ADVERTISE_FAILED_ALREADY_STARTED -> "蓝牙广播已经在运行"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "这台手机不支持低功耗蓝牙广播"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "蓝牙广播内部错误"
                else -> "启动蓝牙广播失败（$errorCode）"
            }
            fail(reason)
        }
    }

    // MARK: - GATT callback

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            if (status == BluetoothGatt.GATT_SUCCESS && service?.uuid == BleProtocol.SERVICE_UUID) {
                startAdvertising()
            } else {
                fail("注册蓝牙服务失败（$status）")
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
            if (device == null) return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedDevice = device
                lastMacContactElapsed = SystemClock.elapsedRealtime()
                disarmSendTimeout()
                stopAdvertising()
                isSubscribed = false
                isPaired = false
                failedAttempts = 0
                incomingReassembler.reset()
                synchronized(outgoingLock) {
                    outgoingQueue.clear()
                    isSending = false
                }
                RelayState.centralConnected = true
                RelayState.paired = false
                setBluetoothState("Mac 已连接，等待配对")
                startMacWatchdog()
                Log.i(TAG, "Central connected")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                stopMacWatchdog()
                disarmSendTimeout()
                if (connectedDevice == device) {
                    connectedDevice = null
                    isSubscribed = false
                    isPaired = false
                    failedAttempts = 0
                    incomingReassembler.reset()
                    synchronized(outgoingLock) {
                        outgoingQueue.clear()
                        isSending = false
                    }
                    RelayState.centralConnected = false
                    RelayState.paired = false
                    setBluetoothState("等待 Mac 连接")
                    Log.i(TAG, "Central disconnected")
                }
                mainHandler.postDelayed({ startAdvertising() }, 600)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            descriptor: BluetoothGattDescriptor?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            if (device == null) return
            var success = false
            var enabled = false
            if (descriptor != null && descriptor.uuid == BleProtocol.CCCD_UUID) {
                enabled = value != null && value.isNotEmpty() && (value[0].toInt() and 0x01) != 0
                isSubscribed = enabled
                success = true
            }

            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        if (success) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                        offset,
                        null
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "sendResponse failed", e)
                }
            }

            if (success && enabled) {
                lastMacContactElapsed = SystemClock.elapsedRealtime()
                startMacWatchdog()
                RelayState.centralConnected = true
                setBluetoothState("Mac 已连接，等待配对")
                sendStatus("waiting_for_pin", "请输入手机上的 6 位配对码")
            } else if (success && !enabled) {
                isSubscribed = false
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            if (device == null) return
            val isRx = characteristic?.uuid == BleProtocol.RX_UUID
            if (isRx) {
                lastMacContactElapsed = SystemClock.elapsedRealtime()
            }
            val valid = isRx && !preparedWrite && offset == 0 && value != null

            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                        offset,
                        null
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "sendResponse failed", e)
                }
            }

            if (!valid) return
            val bytes = value ?: return
            val completed = incomingReassembler.ingest(bytes) ?: return
            handleCommand(completed, device)
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice?,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic?
        ) {
            if (device == null) return
            try {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_READ_NOT_PERMITTED,
                    offset,
                    null
                )
            } catch (e: Exception) {
                Log.w(TAG, "sendResponse failed", e)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice?, status: Int) {
            mainHandler.post {
                disarmSendTimeout()
                synchronized(outgoingLock) { isSending = false }
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    drainQueue()
                } else {
                    synchronized(outgoingLock) { outgoingQueue.clear() }
                    Log.w(TAG, "Notification send failed: $status")
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice?, mtu: Int) {
            Log.d(TAG, "MTU changed to $mtu")
        }
    }

    // MARK: - Pairing and messages

    private fun handleCommand(payload: ByteArray, device: BluetoothDevice) {
        if (connectedDevice != device) return
        lastMacContactElapsed = SystemClock.elapsedRealtime()
        val json = try {
            JSONObject(String(payload, StandardCharsets.UTF_8))
        } catch (e: Exception) {
            Log.w(TAG, "Ignoring malformed command")
            return
        }
        if (json.optInt("v", 0) != 1) return
        when (json.optString("type")) {
            "pair" -> handlePair(json.optString("pin"), device)
            "ping" -> Unit
            else -> Log.d(TAG, "Ignoring unknown command")
        }
    }

    private fun handlePair(supplied: String, device: BluetoothDevice) {
        if (supplied == pin) {
            isPaired = true
            failedAttempts = 0
            RelayState.paired = true
            RelayState.lastError = null
            val notificationAccess = isNotificationAccessEnabled()
            RelayState.listenerConnected = notificationAccess
            setBluetoothState(if (notificationAccess) "已连接并配对" else "已连接并配对，但通知访问未开启")
            sendStatus(
                "paired",
                if (notificationAccess) "notifications=on" else "notifications=off"
            )
            Log.i(TAG, "Pairing succeeded (notification access: $notificationAccess)")
            return
        }

        isPaired = false
        RelayState.paired = false
        failedAttempts++
        RelayState.lastError = "配对码错误"
        setBluetoothState("配对码错误（第 $failedAttempts 次）")
        sendStatus("pairing_failed", "配对码错误")
        Log.w(TAG, "Pairing failed")
        if (failedAttempts >= 5) {
            setBluetoothState("配对失败次数过多，已断开")
            try {
                gattServer?.cancelConnection(device)
            } catch (e: Exception) {
                Log.w(TAG, "Unable to cancel connection", e)
            }
        }
    }

    private fun publish(json: String) {
        if (!isPaired || !isSubscribed || connectedDevice == null) return
        enqueue(json, requirePaired = true)
    }

    private fun sendStatus(state: String, detail: String?) {
        if (!isSubscribed || connectedDevice == null) return
        val json = JSONObject()
            .put("v", 1)
            .put("type", "status")
            .put("state", state)
        if (!detail.isNullOrEmpty()) json.put("detail", detail)
        enqueue(json.toString(), requirePaired = false)
    }

    private fun enqueue(json: String, requirePaired: Boolean) {
        if (!isSubscribed || connectedDevice == null) return
        if (requirePaired && !isPaired) return

        val bytes = json.toByteArray(StandardCharsets.UTF_8)
        val frames = synchronized(outgoingLock) {
            if (outgoingQueue.size > MAX_QUEUE_FRAMES) {
                outgoingQueue.clear()
                Log.w(TAG, "BLE queue overflow; dropping pending frames")
            }
            val sequence = outgoingSequence
            outgoingSequence = (outgoingSequence + 1) and 0xFFFF
            FrameCodec.encode(bytes, sequence).also { outgoingQueue.addAll(it) }
        }
        if (frames.isEmpty()) return
        mainHandler.post { drainQueue() }
    }

    @Suppress("DEPRECATION")
    private fun drainQueue() {
        if (destroyed) return
        val item = synchronized(outgoingLock) {
            if (isSending || !isSubscribed) return
            val device = connectedDevice ?: return
            val server = gattServer ?: return
            val characteristic = txCharacteristic ?: return
            if (outgoingQueue.isEmpty()) return
            val frame = outgoingQueue.removeFirst()
            isSending = true
            SendItem(device, server, characteristic, frame)
        }

        val success = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                item.server.notifyCharacteristicChanged(
                    item.device,
                    item.characteristic,
                    false,
                    item.frame
                ) == 0
            } else {
                item.characteristic.value = item.frame
                item.server.notifyCharacteristicChanged(item.device, item.characteristic, false)
            }
        } catch (e: Exception) {
            Log.w(TAG, "notifyCharacteristicChanged failed", e)
            false
        }

        if (success) {
            armSendTimeout(item.device)
        } else {
            disarmSendTimeout()
            synchronized(outgoingLock) {
                isSending = false
                outgoingQueue.clear()
            }
            Log.w(TAG, "BLE notification send failed")
        }
    }
}
