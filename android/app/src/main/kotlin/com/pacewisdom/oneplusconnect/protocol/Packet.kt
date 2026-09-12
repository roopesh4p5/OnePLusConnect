package com.pacewisdom.oneplusconnect.protocol

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException

/** Packet types shared with the Mac (see PROTOCOL.md). */
object PacketType {
    const val HELLO = 0x01
    const val HELLO_ACK = 0x02
    const val CONFIG = 0x03
    const val CONFIG_ACK = 0x04
    const val SESSION_STOP = 0x06

    const val VIDEO = 0x10
    const val KEYFRAME = 0x11
    const val VIDEO_CONFIG = 0x12
    const val REQUEST_KEYFRAME = 0x13

    const val TOUCH = 0x20
    const val GESTURE = 0x21
    const val STYLUS = 0x22
    const val ORIENTATION = 0x23

    const val PING = 0x30
    const val PONG = 0x31
    const val STATS = 0x32

    const val ERROR = 0x40
    const val DISCONNECT = 0x41
}

object PacketFlags {
    const val KEYFRAME = 1 shl 0
    const val END_OF_FRAME = 1 shl 1
}

object Clock {
    /** Microseconds since the Unix epoch; the Mac uses the same base. */
    fun nowMicros(): Long = System.currentTimeMillis() * 1000L
}

class Packet(
    val type: Int,
    val payload: ByteArray = EMPTY,
    val flags: Int = 0,
    val sessionId: Long = 0,
    val sequence: Long = 0,
    val timestamp: Long = Clock.nowMicros(),
) {
    val isKeyframe: Boolean get() = (flags and PacketFlags.KEYFRAME) != 0

    companion object {
        val EMPTY = ByteArray(0)
    }
}

/**
 * Header (28 bytes, big-endian):
 * u32 magic, u8 version, u8 type, u8 flags, u8 reserved, u32 sessionId, u32 sequence, u64 timestamp, u32 payloadLength
 */
object PacketIO {
    const val MAGIC = 0x4F504331
    const val VERSION = 1
    const val HEADER_SIZE = 28
    const val MAX_PAYLOAD = 32 * 1024 * 1024

    fun write(out: DataOutputStream, p: Packet) {
        out.writeInt(MAGIC)
        out.writeByte(VERSION)
        out.writeByte(p.type)
        out.writeByte(p.flags)
        out.writeByte(0)
        out.writeInt(p.sessionId.toInt())
        out.writeInt(p.sequence.toInt())
        out.writeLong(p.timestamp)
        out.writeInt(p.payload.size)
        out.write(p.payload)
        out.flush()
    }

    @Throws(IOException::class)
    fun read(inp: DataInputStream): Packet {
        val magic = inp.readInt()
        if (magic != MAGIC) throw IOException("bad magic 0x${Integer.toHexString(magic)}")
        val version = inp.readUnsignedByte()
        if (version != VERSION) throw IOException("unsupported protocol version $version")
        val type = inp.readUnsignedByte()
        val flags = inp.readUnsignedByte()
        inp.readUnsignedByte() // reserved
        val sessionId = inp.readInt().toLong() and 0xFFFFFFFFL
        val sequence = inp.readInt().toLong() and 0xFFFFFFFFL
        val timestamp = inp.readLong()
        val length = inp.readInt()
        if (length < 0 || length > MAX_PAYLOAD) throw IOException("payload too large: $length")
        val payload = if (length == 0) Packet.EMPTY else ByteArray(length).also { inp.readFully(it) }
        return Packet(type, payload, flags, sessionId, sequence, timestamp)
    }
}
