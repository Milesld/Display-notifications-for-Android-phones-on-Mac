package com.notifybridge.app

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * End-to-end crypto for the optional cloud relay.
 *
 * The 32-byte relay secret is shown by the Android app and pasted into the
 * Mac. HKDF derives three independent values:
 *  - channel id (goes to the server)
 *  - auth token (goes to the server)
 *  - AES-GCM key (never leaves the two devices)
 *
 * The relay therefore cannot read notification content.
 */
object NetCrypto {
    private val SALT = "NotifyBridge-v1".toByteArray(Charsets.UTF_8)
    private const val SECRET_BYTES = 32
    private const val IV_BYTES = 12

    fun generateSecret(): String {
        val bytes = ByteArray(SECRET_BYTES)
        SecureRandom().nextBytes(bytes)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    fun decodeSecret(input: String): ByteArray? {
        var value = input.trim()
        if (value.isEmpty()) return null
        value = value.replace('-', '+').replace('_', '/')
        while (value.length % 4 != 0) value += "="
        return try {
            val bytes = Base64.getDecoder().decode(value)
            if (bytes.size == SECRET_BYTES) bytes else null
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    fun derive(secret: ByteArray, info: String, length: Int): ByteArray {
        val prk = hmac(SALT, secret)
        val output = ByteArrayOutputStream()
        var previous = ByteArray(0)
        var counter = 1
        while (output.size() < length) {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(previous)
            mac.update(info.toByteArray(Charsets.UTF_8))
            mac.update(counter.toByte())
            previous = mac.doFinal()
            output.write(previous)
            counter++
            if (counter > 255) break
        }
        return output.toByteArray().copyOf(length)
    }

    fun channel(secret: ByteArray): String =
        derive(secret, "channel", 16).joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    fun token(secret: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(derive(secret, "auth", 32))

    fun encrypt(secret: ByteArray, plaintext: String, aad: ByteArray): String {
        val key = SecretKeySpec(derive(secret, "enc", 32), "AES")
        val iv = ByteArray(IV_BYTES)
        SecureRandom().nextBytes(iv)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        return JSONObject()
            .put("iv", Base64.getEncoder().encodeToString(iv))
            .put("ct", Base64.getEncoder().encodeToString(ciphertext))
            .toString()
    }

    fun decrypt(secret: ByteArray, payload: String, aad: ByteArray): String? {
        return try {
            val json = JSONObject(payload)
            val iv = Base64.getDecoder().decode(json.getString("iv"))
            val ciphertext = Base64.getDecoder().decode(json.getString("ct"))
            if (iv.size != IV_BYTES || ciphertext.size < 16) return null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val key = SecretKeySpec(derive(secret, "enc", 32), "AES")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            cipher.updateAAD(aad)
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    fun pinEquals(expected: String, supplied: String): Boolean {
        return MessageDigest.isEqual(
            expected.toByteArray(Charsets.UTF_8),
            supplied.toByteArray(Charsets.UTF_8)
        )
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }
}

data class RelayTarget(val host: String, val port: Int) {
    companion object {
        fun parse(raw: String, defaultPort: Int): RelayTarget? {
            val value = raw.trim()
            if (value.isEmpty()) return null
            if (value.startsWith("[")) {
                val close = value.indexOf(']')
                if (close <= 1) return null
                val host = value.substring(1, close)
                val rest = value.substring(close + 1)
                val port = if (rest.startsWith(":")) rest.substring(1).toIntOrNull() ?: return null else defaultPort
                if (port !in 1..65535) return null
                return RelayTarget(host, port)
            }
            if (value.count { it == ':' } > 1) {
                return RelayTarget(value, defaultPort)
            }
            val colon = value.lastIndexOf(':')
            if (colon > 0) {
                val host = value.substring(0, colon)
                val port = value.substring(colon + 1).toIntOrNull() ?: return null
                if (host.isEmpty() || port !in 1..65535) return null
                return RelayTarget(host, port)
            }
            return RelayTarget(value, defaultPort)
        }
    }

    override fun toString(): String = if (host.contains(':')) "[$host]:$port" else "$host:$port"
}