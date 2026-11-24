package com.notifybridge.app

import android.content.Context

/**
 * Cleans up preference files that belonged to connection modes the app no
 * longer supports. Upgrades would otherwise keep stale relay addresses and
 * shared secrets on disk even though nothing reads them anymore.
 */
object LegacySettings {
    private const val NETWORK_PREFS = "notifybridge_network"

    fun purge(context: Context) {
        context.deleteSharedPreferences(NETWORK_PREFS)
    }
}
