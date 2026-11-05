package com.notifybridge.app

import android.content.Context
import android.os.Build

/**
 * Network-only settings. BLE behaviour and the pairing PIN stay in PinStore /
 * NotificationRelayService, so enabling these channels cannot break BLE.
 */
object NetworkPrefs {
    private const val FILE = "notifybridge_network"
    private const val KEY_CLOUD_ENABLED = "cloud_enabled"
    private const val KEY_RELAY_TARGET = "relay_target"
    private const val KEY_RELAY_SECRET = "relay_secret"

    private fun prefs(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun relayTarget(context: Context): String =
        prefs(context).getString(KEY_RELAY_TARGET, "") ?: ""

    fun relaySecret(context: Context): String {
        val existing = prefs(context).getString(KEY_RELAY_SECRET, "") ?: ""
        if (NetCrypto.decodeSecret(existing) != null) return existing
        return ensureSecret(context)
    }

    fun ensureSecret(context: Context): String {
        val existing = prefs(context).getString(KEY_RELAY_SECRET, "") ?: ""
        if (NetCrypto.decodeSecret(existing) != null) return existing
        val generated = NetCrypto.generateSecret()
        prefs(context).edit().putString(KEY_RELAY_SECRET, generated).apply()
        return generated
    }

    fun isCloudEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_CLOUD_ENABLED, false)

    fun saveCloud(context: Context, enabled: Boolean, target: String, secret: String) {
        prefs(context).edit()
            .putBoolean(KEY_CLOUD_ENABLED, enabled)
            .putString(KEY_RELAY_TARGET, target.trim())
            .putString(KEY_RELAY_SECRET, secret.trim())
            .apply()
    }

    fun cloudConfig(context: Context): CloudConfig? {
        if (!isCloudEnabled(context)) return null
        val target = RelayTarget.parse(relayTarget(context), 443) ?: return null
        val secret = NetCrypto.decodeSecret(relaySecret(context)) ?: return null
        return CloudConfig(target, secret)
    }

    fun deviceName(): String = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"
}

data class CloudConfig(val target: RelayTarget, val secret: ByteArray)