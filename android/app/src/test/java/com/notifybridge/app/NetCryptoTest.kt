package com.notifybridge.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class NetCryptoTest {
    // Fixed cross-language vector, also checked by the Swift ProtocolSelfTest.
    private val secret = Base64.getUrlDecoder()
        .decode("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")

    @Test
    fun hkdfMatchesCrossLanguageVector() {
        assertEquals("5f288a7a29b15429de3c7a991d40548d", NetCrypto.channel(secret))
        assertEquals(
            "lF8N7GQrFKxTEng0pmO7zA2hKWauQLguOOwH2eZdKKM",
            NetCrypto.token(secret)
        )
        assertEquals(
            "d7_iqFy5Lq20DaDM65mP85vOdN1qmT77af5WkTI67Tw",
            Base64.getUrlEncoder().withoutPadding()
                .encodeToString(NetCrypto.derive(secret, "enc", 32))
        )
    }

    @Test
    fun secretRoundTrips() {
        val generated = NetCrypto.generateSecret()
        assertEquals(43, generated.length)
        assertNotNull(NetCrypto.decodeSecret(generated))
        assertEquals(32, NetCrypto.decodeSecret(generated)!!.size)
        assertNull(NetCrypto.decodeSecret("not-a-secret"))
        assertNull(NetCrypto.decodeSecret("AAAA"))
    }

    @Test
    fun encryptDecryptRoundTrips() {
        val aad = "channel-aad".toByteArray()
        val plaintext = "微信消息：今晚一起吃饭吗？🍜"
        val encrypted = NetCrypto.encrypt(secret, plaintext, aad)
        assertEquals(plaintext, NetCrypto.decrypt(secret, encrypted, aad))
        assertNull(NetCrypto.decrypt(secret, encrypted, "other-aad".toByteArray()))
    }

    @Test
    fun targetParsing() {
        assertEquals(RelayTarget("example.com", 443), RelayTarget.parse("example.com", 443))
        assertEquals(RelayTarget("example.com", 8443), RelayTarget.parse("example.com:8443", 443))
        assertEquals(RelayTarget("100.64.0.2", 47821), RelayTarget.parse("100.64.0.2:47821", 443))
        assertEquals(RelayTarget("::1", 443), RelayTarget.parse("[::1]", 443))
        assertNull(RelayTarget.parse("", 443))
        assertNull(RelayTarget.parse("host:bad", 443))
        assertTrue(RelayTarget.parse("host", 443)!!.port == 443)
    }
}
