package com.notifybridge.app

import android.content.Context
import java.security.SecureRandom

object PinStore {
    private const val PREFS = "notifybridge"
    private const val KEY_PIN = "pairing_pin"
    private val random = SecureRandom()

    @Synchronized
    fun getOrCreate(context: Context): String {
        val existing = peek(context)
        if (existing != null) return existing
        return refresh(context)
    }

    @Synchronized
    fun refresh(context: Context): String {
        val pin = (random.nextInt(900_000) + 100_000).toString()
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PIN, pin)
            .apply()
        return pin
    }

    fun peek(context: Context): String? {
        val pin = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_PIN, null)
        return if (pin != null && pin.matches(Regex("\\d{6}"))) pin else null
    }
}
