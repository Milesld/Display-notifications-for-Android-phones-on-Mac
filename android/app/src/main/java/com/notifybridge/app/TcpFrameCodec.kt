package com.notifybridge.app

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException

/**
 * Length-prefixed JSON framing for the direct TCP and relay transports.
 * This is deliberately separate from the 20-byte BLE framing.
 */
object TcpFrameCodec {
    const val MAX_FRAME_BYTES = 256 * 1024

    fun encode(json: String): ByteArray {
        val payload = json.toByteArray(Charsets.UTF_8)
        require(payload.isNotEmpty() && payload.size <= MAX_FRAME_BYTES)
        val frame = ByteArray(payload.size + 4)
        val length = payload.size
        frame[0] = ((length ushr 24) and 0xFF).toByte()
        frame[1] = ((length ushr 16) and 0xFF).toByte()
        frame[2] = ((length ushr 8) and 0xFF).toByte()
        frame[3] = (length and 0xFF).toByte()
        System.arraycopy(payload, 0, frame, 4, payload.size)
        return frame
    }

    @Throws(IOException::class)
    fun read(input: DataInputStream): String? {
        val length = try {
            input.readInt()
        } catch (e: EOFException) {
            return null
        }
        if (length <= 0 || length > MAX_FRAME_BYTES) {
            throw IOException("Invalid frame length: $length")
        }
        val payload = ByteArray(length)
        input.readFully(payload)
        return String(payload, Charsets.UTF_8)
    }

    @Synchronized
    @Throws(IOException::class)
    fun write(output: DataOutputStream, json: String) {
        val frame = encode(json)
        output.write(frame)
        output.flush()
    }
}
