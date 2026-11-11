package com.notifybridge.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GattLinkPolicyTest {
    @Test
    fun freshHeartbeatKeepsTheExistingCentral() {
        assertTrue(GattLinkPolicy.shouldKeepExisting(0))
        assertTrue(GattLinkPolicy.shouldKeepExisting(8_000))
        assertFalse(GattLinkPolicy.isStale(8_000))
    }

    @Test
    fun silentCentralStaleAfterThreshold() {
        assertTrue(GattLinkPolicy.isStale(GattLinkPolicy.STALE_CENTRAL_MS))
        assertTrue(GattLinkPolicy.isStale(GattLinkPolicy.STALE_CENTRAL_MS + 1))
        assertTrue(GattLinkPolicy.isStale(Long.MAX_VALUE))
        assertFalse(GattLinkPolicy.shouldKeepExisting(GattLinkPolicy.STALE_CENTRAL_MS))
    }

    @Test
    fun justBelowThresholdIsStillFresh() {
        assertFalse(GattLinkPolicy.isStale(GattLinkPolicy.STALE_CENTRAL_MS - 1))
        assertTrue(GattLinkPolicy.shouldKeepExisting(GattLinkPolicy.STALE_CENTRAL_MS - 1))
    }
}
