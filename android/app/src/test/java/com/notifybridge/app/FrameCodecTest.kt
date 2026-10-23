package com.notifybridge.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets

class FrameCodecTest {
    @Test
    fun shortPayloadUsesOneFrame() {
        val payload = "hello".toByteArray(StandardCharsets.UTF_8)
        val frames = FrameCodec.encode(payload, 7)
        assertEquals(1, frames.size)
        assertEquals(4 + payload.size, frames[0].size)
        assertEquals(BleProtocol.MAGIC, frames[0][0])
        assertEquals((BleProtocol.FLAG_START or BleProtocol.FLAG_END).toByte(), frames[0][1])

        val reassembler = FrameReassembler()
        assertArrayEquals(payload, reassembler.ingest(frames[0]))
    }

    @Test
    fun longChinesePayloadRoundTrips() {
        val original = "微信消息：今晚一起吃饭吗？🍜 ".repeat(80)
        val payload = original.toByteArray(StandardCharsets.UTF_8)
        val frames = FrameCodec.encode(payload, 42)
        assertTrue(frames.size > 1)
        assertTrue(frames.all { it.size <= BleProtocol.NOTIFICATION_MTU })
        assertEquals(BleProtocol.FLAG_START.toByte(), frames.first()[1])
        assertEquals(BleProtocol.FLAG_END.toByte(), frames.last()[1])

        val reassembler = FrameReassembler()
        var result: ByteArray? = null
        for (frame in frames) {
            reassembler.ingest(frame)?.let { result = it }
        }
        assertArrayEquals(payload, result)
        assertEquals(original, result?.toString(StandardCharsets.UTF_8))
    }

    @Test
    fun emptyPayloadUsesOneFrame() {
        val frames = FrameCodec.encode(ByteArray(0), 1)
        assertEquals(1, frames.size)
        val reassembler = FrameReassembler()
        assertArrayEquals(ByteArray(0), reassembler.ingest(frames[0]))
    }

    @Test
    fun sequenceMismatchIsDiscarded() {
        val frames = FrameCodec.encode(ByteArray(40) { 0x41 }, 9)
        assertTrue(frames.size > 1)
        val reassembler = FrameReassembler()
        assertNull(reassembler.ingest(frames[0]))

        val badFirst = frames[0].copyOf()
        badFirst[2] = 10
        assertNull(reassembler.ingest(badFirst))
        assertNull(reassembler.ingest(frames[1]))
    }

    @Test
    fun invalidMagicIsIgnored() {
        val bogus = byteArrayOf(0x00, 0x03, 0x01, 0x00, 0x78)
        val reassembler = FrameReassembler()
        assertNull(reassembler.ingest(bogus))
    }

    @Test
    fun sequenceBytesAreLittleEndian() {
        val frames = FrameCodec.encode("x".toByteArray(), 0x1234)
        assertEquals(0x34.toByte(), frames[0][2])
        assertEquals(0x12.toByte(), frames[0][3])
    }
}
