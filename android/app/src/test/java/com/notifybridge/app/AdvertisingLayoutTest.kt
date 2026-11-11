package com.notifybridge.app

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Legacy BLE advertising data is limited to 31 bytes per packet. The main
 * packet carries flags, the 128-bit service UUID and the 4-byte identity
 * prefix; if that ever grows past the limit, Android reports
 * ADVERTISE_FAILED_DATA_TOO_LARGE and the phone stops advertising entirely.
 */
class AdvertisingLayoutTest {
    private val flagsBytes = 3
    private val serviceUuidBytes = 1 + 1 + 16

    private fun manufacturerBytes(payload: Int) = 1 + 1 + 2 + payload

    @Test
    fun mainPacketFitsLegacyAdvertisingLimit() {
        val total = flagsBytes + serviceUuidBytes + manufacturerBytes(DeviceIdentity.SHORT_BYTE_COUNT)
        assertTrue("main advertisement is $total bytes", total <= 31)
    }

    @Test
    fun fullIdentityFitsScanResponse() {
        val total = flagsBytes + manufacturerBytes(DeviceIdentity.BYTE_COUNT)
        assertTrue("scan response is $total bytes", total <= 31)
    }

    @Test
    fun shortIdentityIsPrefixOfFullIdentity() {
        assertTrue(DeviceIdentity.SHORT_BYTE_COUNT in 1 until DeviceIdentity.BYTE_COUNT)
    }
}
