package com.notifybridge.app

import android.content.Context
import java.security.SecureRandom
import java.util.Locale

/**
 * Stable 8-byte identity advertised in the BLE scan response, with the first
 * four bytes repeated in the main advertising packet because macOS often only
 * reports the first packet to CoreBluetooth apps. Android rotates its BLE
 * address, so this app-level ID lets the Mac recognize the same phone across
 * reconnects even when the peripheral UUID changes.
 */
object DeviceIdentity {
    private const val PREFS = "notifybridge"
    private const val KEY = "device_id"

    /** Full identity advertised in the scan response. */
    const val BYTE_COUNT = 8
    /** First bytes repeated in the main advertising packet (31-byte limit). */
    const val SHORT_BYTE_COUNT = 4

    private val random = SecureRandom()

    @Synchronized
    fun shortBytes(context: Context): ByteArray = bytes(context).copyOf(SHORT_BYTE_COUNT)

    fun bytes(context: Context): ByteArray {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(KEY, null)
        if (stored != null && stored.length == BYTE_COUNT * 2) {
            val bytes = ByteArray(BYTE_COUNT)
            var valid = true
            for (i in 0 until BYTE_COUNT) {
                val value = stored.substring(i * 2, i * 2 + 2).toIntOrNull(16)
                if (value == null) {
                    valid = false
                    break
                }
                bytes[i] = value.toByte()
            }
            if (valid) return bytes
        }

        val generated = ByteArray(BYTE_COUNT)
        random.nextBytes(generated)
        val hex = generated.joinToString("") {
            String.format(Locale.US, "%02X", it.toInt() and 0xFF)
        }
        prefs.edit().putString(KEY, hex).apply()
        return generated
    }
}
