package com.notifybridge.app

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject

class MainActivity : Activity() {
    companion object {
        private const val REQ_PERMISSIONS = 100
        private const val REQ_ENABLE_BLUETOOTH = 101
    }

    private lateinit var notificationStatus: TextView
    private lateinit var notificationButton: Button
    private lateinit var serviceStatus: TextView
    private lateinit var connectionStatus: TextView
    private lateinit var bluetoothState: TextView
    private lateinit var pairingCode: TextView
    private lateinit var listenerHint: TextView
    private lateinit var startStopButton: Button
    private lateinit var refreshPinButton: Button
    private lateinit var testPhoneButton: Button
    private lateinit var macHint: TextView

    private val handler = Handler(Looper.getMainLooper())
    private var pendingStart = false
    private var notificationPermissionRequested = false

    private val refreshRunnable = object : Runnable {
        override fun run() {
            refreshUi()
            handler.postDelayed(this, 1_000)
        }
    }

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = getColor(R.color.background)
        window.navigationBarColor = getColor(R.color.background)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        setContentView(R.layout.activity_main)

        notificationStatus = findViewById(R.id.notification_status)
        notificationButton = findViewById(R.id.notification_button)
        serviceStatus = findViewById(R.id.service_status)
        connectionStatus = findViewById(R.id.connection_status)
        bluetoothState = findViewById(R.id.bluetooth_state)
        pairingCode = findViewById(R.id.pairing_code)
        listenerHint = findViewById(R.id.listener_hint)
        startStopButton = findViewById(R.id.start_stop_button)
        refreshPinButton = findViewById(R.id.refresh_pin_button)
        testPhoneButton = findViewById(R.id.test_phone_button)
        macHint = findViewById(R.id.mac_hint)

        notificationButton.setOnClickListener { openNotificationListenerSettings() }
        startStopButton.setOnClickListener { toggleRelay() }
        refreshPinButton.setOnClickListener { refreshPairingCode() }
        testPhoneButton.setOnClickListener { sendTestMessage() }
    }

    override fun onResume() {
        super.onResume()
        handler.removeCallbacks(refreshRunnable)
        refreshUi()
        handler.post(refreshRunnable)
    }

    override fun onPause() {
        handler.removeCallbacks(refreshRunnable)
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun refreshUi() {
        val hasAccess = isNotificationAccessEnabled()
        RelayState.listenerConnected = hasAccess

        if (hasAccess) {
            notificationStatus.text = getString(R.string.notification_access_granted)
            notificationStatus.setTextColor(getColor(R.color.success))
            notificationButton.text = getString(R.string.manage_access)
        } else {
            notificationStatus.text = getString(R.string.notification_access_missing)
            notificationStatus.setTextColor(getColor(R.color.danger))
            notificationButton.text = getString(R.string.grant_access)
        }
        listenerHint.visibility = if (hasAccess) View.GONE else View.VISIBLE

        val currentPin = PinStore.peek(this) ?: PinStore.getOrCreate(this)
        pairingCode.text = currentPin

        if (RelayState.isRunning) {
            serviceStatus.text = getString(R.string.service_running)
            serviceStatus.setTextColor(getColor(R.color.success))
            startStopButton.text = getString(R.string.stop_sync)
            startStopButton.backgroundTintList = ColorStateList.valueOf(getColor(R.color.danger))
        } else {
            serviceStatus.text = getString(R.string.service_stopped)
            serviceStatus.setTextColor(getColor(R.color.muted))
            startStopButton.text = getString(R.string.start_sync)
            startStopButton.backgroundTintList = ColorStateList.valueOf(getColor(R.color.primary))
        }

        connectionStatus.text = when {
            !RelayState.isRunning -> getString(R.string.connection_not_running)
            RelayState.paired -> getString(R.string.connection_paired)
            RelayState.centralConnected -> getString(R.string.connection_waiting_for_pin)
            else -> getString(R.string.connection_waiting_for_mac)
        }

        val btText = RelayState.bluetoothState
        bluetoothState.text = getString(R.string.bluetooth_state_format, btText)
        bluetoothState.setTextColor(
            if (RelayState.lastError.isNullOrBlank()) getColor(R.color.muted) else getColor(R.color.danger)
        )

        refreshPinButton.isEnabled = RelayState.isRunning && !RelayState.paired
        macHint.text = if (RelayState.isRunning) {
            getString(R.string.mac_hint_running)
        } else {
            getString(R.string.mac_hint_stopped)
        }
    }

    private fun toggleRelay() {
        if (RelayState.isRunning) {
            stopService(Intent(this, NotificationRelayService::class.java))
            RelayState.isRunning = false
            RelayState.centralConnected = false
            RelayState.paired = false
            handler.postDelayed({ refreshUi() }, 300)
            return
        }
        startRelayFlow()
    }

    private fun startRelayFlow() {
        if (!isNotificationAccessEnabled()) {
            openNotificationListenerSettings()
            toast(getString(R.string.toast_enable_notification_access))
            return
        }

        val missing = mutableListOf<String>()
        missing.addAll(missingBluetoothPermissions())
        if (!notificationPermissionRequested) {
            val notificationMissing = missingNotificationPermission()
            if (notificationMissing != null) {
                missing.add(notificationMissing)
                notificationPermissionRequested = true
            }
        }
        if (missing.isNotEmpty()) {
            pendingStart = true
            requestPermissions(missing.toTypedArray(), REQ_PERMISSIONS)
            return
        }

        if (!isBluetoothEnabled()) {
            pendingStart = true
            try {
                startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), REQ_ENABLE_BLUETOOTH)
            } catch (e: Exception) {
                pendingStart = false
                toast(getString(R.string.toast_open_bluetooth_failed))
            }
            return
        }

        launchRelayService()
    }

    private fun launchRelayService() {
        pendingStart = false
        try {
            startForegroundService(Intent(this, NotificationRelayService::class.java))
            toast(getString(R.string.toast_service_starting))
            handler.postDelayed({ refreshUi() }, 500)
        } catch (e: Exception) {
            toast(getString(R.string.toast_service_start_failed, e.message ?: ""))
        }
    }

    private fun sendTestMessage() {
        if (!RelayState.isRunning) {
            toast(getString(R.string.toast_start_first))
            return
        }
        if (!RelayState.paired) {
            toast(getString(R.string.toast_pair_first))
            return
        }
        try {
            val now = System.currentTimeMillis()
            val json = JSONObject()
                .put("v", 1)
                .put("type", "notification")
                .put("id", "phone-test-$now")
                .put("app", "通知桥")
                .put("pkg", packageName)
                .put("title", "手机测试消息")
                .put("text", "如果你在 Mac 上看到这条通知，说明手机到 Mac 的通知通道正常。")
                .put("time", now)
                .put("category", "msg")
            NotificationHub.emit(json.toString())
            toast(getString(R.string.toast_test_sent))
        } catch (e: Exception) {
            toast(getString(R.string.toast_refresh_failed))
        }
    }

    private fun refreshPairingCode() {
        if (!RelayState.isRunning) {
            toast(getString(R.string.toast_start_first))
            return
        }
        try {
            val intent = Intent(this, NotificationRelayService::class.java)
                .setAction(NotificationRelayService.ACTION_REFRESH_PIN)
            startService(intent)
            handler.postDelayed({ refreshUi() }, 250)
        } catch (e: Exception) {
            toast(getString(R.string.toast_refresh_failed))
        }
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

    private fun missingBluetoothPermissions(): List<String> {
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.BLUETOOTH_CONNECT)
            }
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.BLUETOOTH_ADVERTISE)
            }
        } else {
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }
        return missing
    }

    private fun missingNotificationPermission(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            Manifest.permission.POST_NOTIFICATIONS
        } else {
            null
        }
    }

    private fun hasBluetoothPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
                checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
        }
        return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    private fun isBluetoothEnabled(): Boolean {
        return try {
            val manager = getSystemService(BluetoothManager::class.java)
            manager.adapter?.isEnabled == true
        } catch (e: Exception) {
            false
        }
    }

    private fun openNotificationListenerSettings() {
        try {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_SETTINGS))
            } catch (ignored: Exception) {
                toast(getString(R.string.toast_open_settings_failed))
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMISSIONS) return
        if (!hasBluetoothPermissions()) {
            pendingStart = false
            toast(getString(R.string.toast_bluetooth_permission_required))
            return
        }
        if (pendingStart) {
            startRelayFlow()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_ENABLE_BLUETOOTH) {
            if (resultCode == RESULT_OK && pendingStart) {
                startRelayFlow()
            } else {
                pendingStart = false
                if (resultCode != RESULT_OK) {
                    toast(getString(R.string.toast_bluetooth_required))
                }
            }
        }
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }
}
