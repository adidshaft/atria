package com.adidshaft.atria.protocol

import java.util.UUID

/**
 * WHOOP 4.0 ("Harvard") wire format — ported 1:1 from FrameParser.swift.
 *
 *   AA | len:u16 LE | CRC8(len) | inner payload | CRC32(inner payload):u32 LE
 *
 * `len` = payload.size + 4 (the trailing CRC32), so total = len + 4.
 */
object WhoopUuids {
    private fun std(short: String): UUID = UUID.fromString("0000$short-0000-1000-8000-00805f9b34fb")

    val heartRateService: UUID = std("180D")
    val heartRateMeasurement: UUID = std("2A37")
    val batteryService: UUID = std("180F")
    val batteryLevel: UUID = std("2A19")
    val batteryLevelStatus: UUID = std("2A1B")
    val deviceInfoService: UUID = std("180A")
    val manufacturerName: UUID = std("2A29")
    val modelNumber: UUID = std("2A24")
    val firmwareRevision: UUID = std("2A26")
    val hardwareRevision: UUID = std("2A27")
    val clientCharacteristicConfig: UUID = std("2902")

    val strapService: UUID = UUID.fromString("61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    val strapTX: UUID = UUID.fromString("61080002-8d6d-82b8-614a-1c8cb0f8dcc6")
    val strapRX: UUID = UUID.fromString("61080003-8d6d-82b8-614a-1c8cb0f8dcc6")
    val strapStream4: UUID = UUID.fromString("61080004-8d6d-82b8-614a-1c8cb0f8dcc6")
    val strapStream5: UUID = UUID.fromString("61080005-8d6d-82b8-614a-1c8cb0f8dcc6")
    val strapStream7: UUID = UUID.fromString("61080007-8d6d-82b8-614a-1c8cb0f8dcc6")

    /** Production subscriptions: command responses + the verified history/IMU data channel. */
    val productionNotify = listOf(strapRX, strapStream5)
}

object PacketType {
    const val COMMAND: Int = 0x23
    const val COMMAND_RESPONSE: Int = 0x24
    const val REALTIME: Int = 0x28
    const val REALTIME_RAW: Int = 0x2B
    const val HISTORICAL: Int = 0x2F
    const val EVENT: Int = 0x30
    const val METADATA: Int = 0x31
    const val CONSOLE_LOG: Int = 0x32
    const val IMU: Int = 0x33
}

object Cmd {
    const val LINK_VALID: Int = 0x01
    const val TOGGLE_REALTIME_HR: Int = 0x03
    const val SET_CLOCK: Int = 0x0A
    const val GET_CLOCK: Int = 0x0B
    const val ABORT_HISTORICAL_TRANSMITS: Int = 0x14
    const val SEND_HISTORICAL_DATA: Int = 0x16
    const val HISTORICAL_DATA_RESULT: Int = 0x17
    const val FORCE_TRIM: Int = 0x19
    const val GET_BATTERY_LEVEL: Int = 0x1A
    const val GET_DATA_RANGE: Int = 0x22
    const val SEND_R10_R11_REALTIME: Int = 0x3F
    const val RUN_HAPTICS_PATTERN: Int = 0x4F
    const val START_RAW_DATA: Int = 0x51
    const val STOP_RAW_DATA: Int = 0x52
    const val TOGGLE_IMU_MODE_HISTORICAL: Int = 0x69
    const val TOGGLE_IMU_MODE: Int = 0x6A
    const val STOP_HAPTICS: Int = 0x7A

    /** Haptic body proven on device: pattern 2, N pulses. */
    fun hapticPayload(pulses: Int): ByteArray =
        byteArrayOf(0x02, pulses.coerceIn(1, 10).toByte(), 0, 0, 0)

    fun setClockPayload(unixSeconds: Long): ByteArray {
        val v = unixSeconds.coerceIn(0, 0xFFFF_FFFFL)
        return byteArrayOf(
            (v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte(),
            ((v shr 16) and 0xFF).toByte(), ((v shr 24) and 0xFF).toByte(), 0, 0, 0, 0,
        )
    }
}

object Crc {
    private val table = IntArray(256) { index ->
        var c = index
        repeat(8) { c = if (c and 1 != 0) (c ushr 1) xor 0xEDB88320.toInt() else c ushr 1 }
        c
    }

    /** CRC-32/ISO-HDLC (zlib). Table-driven: the bitwise form starved the BLE queue on iOS. */
    fun crc32(bytes: ByteArray, from: Int = 0, to: Int = bytes.size): Long {
        var crc = -1
        for (i in from until to) {
            crc = table[(crc xor bytes[i].toInt()) and 0xFF] xor (crc ushr 8)
        }
        return (crc.inv().toLong()) and 0xFFFF_FFFFL
    }

    /** CRC-8 poly 0x07 init 0x00 over the two length bytes. */
    fun crc8(vararg bytes: Byte): Int {
        var c = 0
        for (b in bytes) {
            c = c xor (b.toInt() and 0xFF)
            repeat(8) { c = if (c and 0x80 != 0) ((c shl 1) xor 0x07) and 0xFF else (c shl 1) and 0xFF }
        }
        return c
    }
}

object FrameCodec {
    fun encode(payload: ByteArray): ByteArray {
        val len = payload.size + 4
        val lo = (len and 0xFF).toByte()
        val hi = ((len shr 8) and 0xFF).toByte()
        val out = ByteArray(4 + payload.size + 4)
        out[0] = 0xAA.toByte(); out[1] = lo; out[2] = hi
        out[3] = Crc.crc8(lo, hi).toByte()
        payload.copyInto(out, 4)
        val c = Crc.crc32(payload)
        val o = 4 + payload.size
        out[o] = (c and 0xFF).toByte()
        out[o + 1] = ((c shr 8) and 0xFF).toByte()
        out[o + 2] = ((c shr 16) and 0xFF).toByte()
        out[o + 3] = ((c shr 24) and 0xFF).toByte()
        return out
    }

    fun command(sequence: Int, command: Int, body: ByteArray): ByteArray =
        encode(byteArrayOf(PacketType.COMMAND.toByte(), sequence.toByte(), command.toByte()) + body)

    /** Inner payload of a complete frame (packet type first), or null if not well-formed. */
    fun payloadOf(frame: ByteArray): ByteArray? {
        if (frame.size < 9 || frame[0] != 0xAA.toByte()) return null
        val len = u16(frame, 1)
        if (len < 5 || len + 4 > frame.size) return null
        return frame.copyOfRange(4, len)
    }
}

internal fun u8(b: ByteArray, o: Int): Int = b[o].toInt() and 0xFF
internal fun u16(b: ByteArray, o: Int): Int = u8(b, o) or (u8(b, o + 1) shl 8)
internal fun i16(b: ByteArray, o: Int): Int = u16(b, o).toShort().toInt()
internal fun u32(b: ByteArray, o: Int): Long =
    (u8(b, o).toLong()) or (u8(b, o + 1).toLong() shl 8) or (u8(b, o + 2).toLong() shl 16) or (u8(b, o + 3).toLong() shl 24)
internal fun f32(b: ByteArray, o: Int): Float = java.lang.Float.intBitsToFloat(u32(b, o).toInt())

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xFF) }

/**
 * Per-characteristic reassembly of notify fragments into CRC-verified frames.
 * Mirrors AtriaWhoop4FrameReassembler: realign on a plausible header (AA, CRC8
 * of the length), drop CRC failures one byte at a time, but admit an isolated
 * complete frame whose CRC does not match (live compact IMU trailers often use
 * a different CRC, proven on device 2026-09-15).
 */
class FrameReassembler(
    private val maximumFrameBytes: Int = 4096,
    private val maximumBufferedBytes: Int = 8192,
) {
    private val buffers = HashMap<String, ByteArrayBuilder>()

    @Synchronized
    fun feed(fragment: ByteArray, source: String): List<ByteArray> {
        if (fragment.isEmpty()) return emptyList()
        val buffer = buffers.getOrPut(source) { ByteArrayBuilder() }
        buffer.append(fragment)
        val frames = ArrayList<ByteArray>()
        while (true) {
            if (!alignToPlausibleHeader(buffer)) break
            if (buffer.size < 4) break
            val declared = buffer[1] or (buffer[2] shl 8)
            val total = declared + 4
            if (buffer.size < total) break
            val bytes = buffer.toByteArray(total)
            val actual = u32(bytes, declared)
            if (Crc.crc32(bytes, 4, declared) != actual) {
                if (buffer.size == total) {
                    frames += bytes
                    buffer.clear()
                    break
                }
                buffer.removeFirst(1)
                continue
            }
            frames += bytes
            buffer.removeFirst(total)
            while (buffer.size > 0 && buffer[0] == 0) buffer.removeFirst(1)
        }
        if (buffer.size > maximumBufferedBytes) buffer.clear()
        return frames
    }

    @Synchronized
    fun reset(source: String? = null) {
        if (source == null) buffers.clear() else buffers.remove(source)
    }

    private fun alignToPlausibleHeader(buffer: ByteArrayBuilder): Boolean {
        var index = 0
        while (index < buffer.size) {
            if (buffer[index] != 0xAA) { index++; continue }
            if (index + 3 >= buffer.size) {
                if (index > 0) buffer.removeFirst(index)
                return false
            }
            val lo = buffer[index + 1]
            val hi = buffer[index + 2]
            val declared = lo or (hi shl 8)
            if (buffer[index + 3] == Crc.crc8(lo.toByte(), hi.toByte()) && declared >= 5 && declared + 4 <= maximumFrameBytes) {
                if (index > 0) buffer.removeFirst(index)
                return true
            }
            index++
        }
        buffer.clear()
        return false
    }
}

/** Minimal growable unsigned byte buffer. */
class ByteArrayBuilder {
    private var data = ByteArray(256)
    var size = 0
        private set

    operator fun get(i: Int): Int = data[i].toInt() and 0xFF

    fun append(bytes: ByteArray) {
        if (size + bytes.size > data.size) data = data.copyOf(maxOf(data.size * 2, size + bytes.size))
        bytes.copyInto(data, size)
        size += bytes.size
    }

    fun removeFirst(n: Int) {
        val k = n.coerceAtMost(size)
        data.copyInto(data, 0, k, size)
        size -= k
    }

    fun clear() { size = 0 }
    fun toByteArray(n: Int = size): ByteArray = data.copyOf(n)
}
