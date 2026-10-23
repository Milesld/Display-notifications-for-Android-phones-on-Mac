package com.notifybridge.app

import java.io.ByteArrayOutputStream
import java.util.UUID

object BleProtocol {
    val SERVICE_UUID: UUID = UUID.fromString("9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D01")
    val TX_UUID: UUID = UUID.fromString("9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D02")
    val RX_UUID: UUID = UUID.fromString("9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D03")
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val NOTIFICATION_MTU = 20
    const val HEADER_SIZE = 4
    const val CHUNK_SIZE = NOTIFICATION_MTU - HEADER_SIZE
    const val MAX_MESSAGE_BYTES = 64 * 1024

    const val MAGIC: Byte = 0x4E
    const val FLAG_START = 0x01
    const val FLAG_END = 0x02
}

object FrameCodec {
    /** Split a UTF-8 JSON payload into 20-byte BLE notification frames. */
    fun encode(payload: ByteArray, sequence: Int): List<ByteArray> {
        require(payload.size <= BleProtocol.MAX_MESSAGE_BYTES) { "message too large" }
        val frames = ArrayList<ByteArray>()
        var offset = 0
        do {
            val end = minOf(offset + BleProtocol.CHUNK_SIZE, payload.size)
            var flags = 0
            if (offset == 0) flags = flags or BleProtocol.FLAG_START
            if (end == payload.size) flags = flags or BleProtocol.FLAG_END

            val frame = ByteArray(BleProtocol.HEADER_SIZE + (end - offset))
            frame[0] = BleProtocol.MAGIC
            frame[1] = flags.toByte()
            frame[2] = (sequence and 0xFF).toByte()
            frame[3] = ((sequence shr 8) and 0xFF).toByte()
            System.arraycopy(payload, offset, frame, BleProtocol.HEADER_SIZE, end - offset)
            frames.add(frame)
            offset = end
        } while (offset < payload.size)
        return frames
    }
}

class FrameReassembler {
    private val buffer = ByteArrayOutputStream()
    private var active = false
    private var sequence = 0

    @Synchronized
    fun ingest(data: ByteArray): ByteArray? {
        if (data.size < BleProtocol.HEADER_SIZE || data[0] != BleProtocol.MAGIC) {
            reset()
            return null
        }
        val flags = data[1].toInt() and 0xFF
        val frameSequence = (data[2].toInt() and 0xFF) or ((data[3].toInt() and 0xFF) shl 8)

        if (flags and BleProtocol.FLAG_START != 0) {
            buffer.reset()
            active = true
            sequence = frameSequence
        }
        if (!active || frameSequence != sequence) {
            reset()
            return null
        }

        buffer.write(data, BleProtocol.HEADER_SIZE, data.size - BleProtocol.HEADER_SIZE)
        if (buffer.size() > BleProtocol.MAX_MESSAGE_BYTES) {
            reset()
            return null
        }

        if (flags and BleProtocol.FLAG_END != 0) {
            val payload = buffer.toByteArray()
            reset()
            return payload
        }
        return null
    }

    @Synchronized
    fun reset() {
        buffer.reset()
        active = false
    }
}
