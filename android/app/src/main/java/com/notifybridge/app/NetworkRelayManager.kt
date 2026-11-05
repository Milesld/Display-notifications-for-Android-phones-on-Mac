package com.notifybridge.app

import android.content.Context
import android.util.Log

/**
 * Owns the optional network channels. BLE is untouched: the relay service calls
 * publish() for every notification and this class fans it out to LAN/Tailscale
 * and, when configured, to the encrypted cloud relay.
 */
class NetworkRelayManager(
    context: Context,
    pinProvider: () -> String,
    notificationAccessProvider: () -> Boolean,
    private val onStateChanged: () -> Unit
) {
    private val appContext = context.applicationContext
    private val lan = LanRelayServer(
        appContext,
        pinProvider,
        notificationAccessProvider
    ) { state, clients ->
        RelayState.lanState = state
        RelayState.lanClients = clients
        onStateChanged()
    }
    private var cloud: CloudRelayClient? = null

    fun start() {
        RelayState.lanState = "局域网：正在启动…"
        lan.start()
        applyCloudConfig()
    }

    fun stop() {
        lan.stop()
        cloud?.stop()
        cloud = null
        RelayState.lanState = "局域网：已停止"
        RelayState.lanClients = 0
        RelayState.cloudState = "云中转：未配置"
        RelayState.cloudConnected = false
        onStateChanged()
    }

    fun updatePin() {
        lan.updatePin()
        // The PIN is read through the provider on every authentication; cloud
        // relay auth uses the separate end-to-end secret.
    }

    fun reload() {
        cloud?.stop()
        cloud = null
        RelayState.cloudConnected = false
        applyCloudConfig()
    }

    fun publish(json: String) {
        lan.publish(json)
        cloud?.publish(json)
    }

    private fun applyCloudConfig() {
        val config = NetworkPrefs.cloudConfig(appContext)
        if (config == null) {
            val enabled = NetworkPrefs.isCloudEnabled(appContext)
            RelayState.cloudState = if (enabled) "云中转：地址或密钥无效" else "云中转：未配置"
            RelayState.cloudConnected = false
            onStateChanged()
            return
        }
        try {
            val client = CloudRelayClient(appContext) { state, connected ->
                RelayState.cloudState = state
                RelayState.cloudConnected = connected
                onStateChanged()
            }
            cloud = client
            client.start(config)
        } catch (e: Exception) {
            Log.w("NotifyBridge", "Unable to start cloud relay", e)
            RelayState.cloudState = "云中转：启动失败"
            RelayState.cloudConnected = false
            onStateChanged()
        }
    }
}
