package com.notifybridge.app

/**
 * Decides what to do when a second central connects while one is already
 * registered. Kept free of Android types so the policy can be unit-tested.
 *
 * The Mac keeps its end of a BLE link across system sleep, and the phone can
 * miss the disconnect callback entirely (frozen app, stack restart). That
 * leftover link never sends another heartbeat, yet it used to reject every
 * reconnect, which is what made the Mac see "phone found, connection dies
 * instantly" forever. A silent central is therefore replaced by the newcomer
 * instead of blocking it.
 */
object GattLinkPolicy {
    /** A central that has been silent for this long is treated as a leftover. */
    const val STALE_CENTRAL_MS = 10_000L

    fun isStale(idleMs: Long, thresholdMs: Long = STALE_CENTRAL_MS): Boolean =
        idleMs >= thresholdMs

    /** True when the existing link is alive enough to keep and the newcomer must be rejected. */
    fun shouldKeepExisting(idleMs: Long, thresholdMs: Long = STALE_CENTRAL_MS): Boolean =
        !isStale(idleMs, thresholdMs)
}
