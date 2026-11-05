package com.notifybridge.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

class TcpFrameTest {
    @Test
    fun frameRoundTrips() {
        val json = "{\"type\":\"notification\",\"text\":\"你好\"}"
        val frame = TcpFrameCodec.encode(json)
        assertEquals(frame.size - 4, java.nio.ByteBuffer.wrap(frame, 0, 4).int)

        val input = DataInputStream(ByteArrayInputStream(frame))
        assertEquals(json, TcpFrameCodec.read(input))
        assertNull(TcpFrameCodec.read(input))
    }

    @Test
    fun multipleFramesReadInOrder() {
        val buffer = ByteArrayOutputStream()
        val output = DataOutputStream(buffer)
        TcpFrameCodec.write(output, "first")
        TcpFrameCodec.write(output, "第二条")
        TcpFrameCodec.write(output, "third")
        val input = DataInputStream(ByteArrayInputStream(buffer.toByteArray()))
        assertEquals("first", TcpFrameCodec.read(input))
        assertEquals("第二条", TcpFrameCodec.read(input))
        assertEquals("third", TcpFrameCodec.read(input))
        assertNull(TcpFrameCodec.read(input))
    }

    @Test
    fun oversizedFrameIsRejected() {
        val header = byteArrayOf(0x00, 0x40, 0x00, 0x01, 0x7B, 0x7D)
        val input = DataInputStream(ByteArrayInputStream(header))
        try {
            TcpFrameCodec.read(input)
            throw AssertionError("expected IOException")
        } catch (e: java.io.IOException) {
            assertTrue(e.message!!.contains("Invalid frame length"))
        }
    }
}