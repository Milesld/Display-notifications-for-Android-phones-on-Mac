package com.notifybridge.app

import android.content.Context
import java.security.SecureRandom
import java.util.Locale

/**
 * Stable 8-byte identity advertised in the BLE scan response. Android rotates
 * its BLE address, so this app-level ID lets the Mac recognize the same phone
 * across reconnects even when the peripheral UUID changes.
 */
object DeviceIdentity {
    private const val PREFS = "notifybridge"
    private const val KEY = "device_id"
    private val random = SecureRandom()

    @Synchronized
    fun bytes(context: Context): ByteArray {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(KEY, null)
        if (stored != null && stored.length == 16) {
            val bytes = ByteArray(8)
            var valid = true
            for (i in 0 until 8) {
                val value = stored.substring(i * 2, i * 2 + 2).toIntOrNull(16)
                if (value == null) {
                    valid = false
                    break
                }
                bytes[i] = value.toByte()
            }
            if (valid) return bytes
        }

        val generated = ByteArray(8)
        random.nextBytes(generated)
        val hex = generated.joinToString("") {
            String.format(Locale.US, "%02X", it.toInt() and 0xFF)
        }
        prefs.edit().putString(KEY, hex).apply()
        return generated
    }
}
