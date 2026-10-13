package com.adidshaft.atria.protocol

import kotlin.math.sqrt

/** `24 | responseSeq | opcode | echoedRequestSeq | status | body...` */
data class CommandResponse(
    val responseSequence: Int,
    val opcode: Int,
    val echoedRequestSequence: Int,
    val status: Int?,
    val body: ByteArray,
    val raw: ByteArray,
) {
    val accepted get() = status == 0x01
    val unsupported get() = status == 0x03

    companion object {
        fun parse(payload: ByteArray): CommandResponse? {
            if (payload.size < 4 || u8(payload, 0) != PacketType.COMMAND_RESPONSE) return null
            return CommandResponse(
                responseSequence = u8(payload, 1),
                opcode = u8(payload, 2),
                echoedRequestSequence = u8(payload, 3),
                status = if (payload.size >= 5) u8(payload, 4) else null,
                body = if (payload.size > 5) payload.copyOfRange(5, payload.size) else ByteArray(0),
                raw = payload,
            )
        }
    }
}

/** 0x22 GET_DATA_RANGE response: the strap ring buffer cursors. */
data class HistoryCursorRange(
    val writeCursor: Long,
    val readCursor: Long,
    val capacity: Long,
    val pendingRecords: Long,
    val deviceUnix: Long?,
) {
    companion object {
        fun parse(payload: ByteArray): HistoryCursorRange? {
            if (payload.size < 30 || u8(payload, 0) != 0x24 || u8(payload, 2) != Cmd.GET_DATA_RANGE) return null
            val d = payload.copyOfRange(4, payload.size)
            if (d.size < 26) return null
            val write = u32(d, 10)
            val read = u32(d, 14)
            val capacity = u32(d, 22)
            if (capacity !in 1_024..1_048_576 || write >= capacity || read >= capacity) return null
            val pending = if (write >= read) write - read else write + (capacity - read)
            return HistoryCursorRange(write, read, capacity, pending, if (payload.size >= 66) u32(d, 58) else null)
        }
    }
}

/** 0x0B GET_CLOCK: the single plausible u32 within ±24 h of wall time. */
object ClockResponse {
    fun deviceUnix(payload: ByteArray, wallUnix: Long): Long? {
        if (payload.size < 7 || u8(payload, 0) != 0x24 || u8(payload, 2) != Cmd.GET_CLOCK) return null
        val values = (3..payload.size - 4).map { u32(payload, it) }
            .filter { it > 0 && kotlin.math.abs(wallUnix - it) <= 86_400 }.toSet()
        return values.singleOrNull()
    }
}

/** 0x31 history metadata markers. */
sealed interface HistoryMarker {
    data class Start(val sequence: Int) : HistoryMarker
    data class End(val sequence: Int, val statusWord: Long, val token: ByteArray) : HistoryMarker {
        /** 0x17 HISTORICAL_DATA_RESULT body: 01 + opaque 8-byte continuation token. */
        val ackPayload: ByteArray get() = byteArrayOf(0x01) + token
    }
    data class Complete(val sequence: Int) : HistoryMarker

    companion object {
        fun parse(p: ByteArray): HistoryMarker? {
            if (p.size < 3 || u8(p, 0) != PacketType.METADATA) return null
            val seq = u8(p, 1)
            return when (u8(p, 2)) {
                0x01 -> Start(seq)
                0x02 -> if (p.size >= 21) End(seq, u32(p, 9), p.copyOfRange(13, 21)) else null
                0x03 -> Complete(seq)
                else -> null
            }
        }
    }
}

data class Gravity(val x: Double, val y: Double, val z: Double) {
    val magnitude get() = sqrt(x * x + y * y + z * z)
    val isFinite get() = x.isFinite() && y.isFinite() && z.isFinite()
}

/** Type-47 historical record (layouts v7/v9/v12/v18/v24/v25). */
data class HistoricalRecord(
    val layout: Int,
    val timestampSeconds: Long,
    val subsecond: Int?,
    val counter: Long,
    val gravity: Gravity,
    val motionScalar: Double?,
    val motionTickCounter: Int?,
    /** Gated physiology: null if withheld (off-wrist, out of range). */
    val heartRate: Int?,
    val rrIntervalsMs: List<Int>,
    val withheldReason: String?,
) {
    companion object {
        private val hrOffset = mapOf(7 to 27, 18 to 14, 9 to 17, 12 to 17, 24 to 17)
        private val legacyHROnly = setOf(7, 9, 18)

        fun decode(p: ByteArray): HistoricalRecord? {
            if (p.size < 2 || u8(p, 0) != PacketType.HISTORICAL) return null
            val layout = u8(p, 1)
            return when (layout) {
                25 -> decodeV25(p)
                7, 9, 12, 18, 24 -> decodeFixed(p, layout)
                else -> null
            }
        }

        private fun decodeFixed(p: ByteArray, layout: Int): HistoricalRecord? {
            if (p.size < 48) return null
            val rrCount = u8(p, 18)
            if (rrCount !in 0..4) return null
            val g = Gravity(f32(p, 36).toDouble(), f32(p, 40).toDouble(), f32(p, 44).toDouble())
            if (!g.isFinite) return null
            val rr = (0 until rrCount).map { i16(p, 19 + it * 2) }
            val hr = u8(p, hrOffset.getValue(layout))
            val tick = if (layout == 24 && p.size >= 90) u16(p, 88) else null
            val scalar = if (layout == 24) f32(p, 32).toDouble().takeIf { it.isFinite() && it in 0.0..8.0 } else null
            val reason = when {
                hr == 0 -> "off_wrist"
                hr !in 25..230 -> "hr_out_of_range"
                rr.any { it !in 250..2500 } -> "rr_out_of_range"
                layout in legacyHROnly && g.magnitude !in 0.5..1.8 -> "gravity_out_of_range"
                else -> null
            }
            return HistoricalRecord(
                layout, u32(p, 7), u16(p, 11), u32(p, 3), g, scalar, tick,
                heartRate = if (reason == null) hr else null,
                rrIntervalsMs = if (reason == null) rr else emptyList(),
                withheldReason = reason,
            )
        }

        private fun decodeV25(p: ByteArray): HistoricalRecord? {
            if (p.size < 75) return null
            val s = 16_384.0
            val g = Gravity(i16(p, 69) / s, i16(p, 71) / s, i16(p, 73) / s)
            if (!g.isFinite || g.magnitude !in 0.5..1.5) return null
            return HistoricalRecord(25, u32(p, 7), null, u32(p, 3), g, null, null, null, emptyList(), "no_physiology_v25")
        }
    }
}

data class Vector3(val x: Double, val y: Double, val z: Double) {
    val magnitude get() = sqrt(x * x + y * y + z * z)
}

/** Type-43 R10 realtime record (1,920+ bytes). */
data class R10Record(
    val deviceSecond: Long,
    val heartRate: Int,
    val rrIntervalsMs: List<Int>,
    val firmwareStepCounter: Int,
    val skinTemperatureRaw: Int,
    val isCharging: Boolean,
    val acceleration: List<Vector3>,
    val rotationRate: List<Vector3>,
) {
    val skinTemperatureCelsius get() = skinTemperatureRaw / 10.0

    companion object {
        const val ACCEL_SCALE = 1.0 / 4096.0
        const val GYRO_SCALE = 0.06103515625
        private val accelOffsets = intArrayOf(85, 285, 485)
        private val gyroOffsets = intArrayOf(688, 888, 1088)

        fun decode(p: ByteArray): R10Record? {
            if (p.size < 1288 || u8(p, 0) != PacketType.REALTIME_RAW || u8(p, 1) != 0x0A) return null
            val rrCount = u8(p, 18)
            val rr = if (rrCount <= 4) (0 until rrCount).map { u16(p, 19 + 2 * it) } else emptyList()
            return R10Record(
                deviceSecond = u32(p, 7),
                heartRate = u8(p, 17),
                rrIntervalsMs = rr,
                firmwareStepCounter = if (p.size >= 1295) u16(p, 1293) else 0,
                skinTemperatureRaw = if (p.size >= 1919) u16(p, 1917) else 0,
                isCharging = u8(p, 2) and 0x02 != 0,
                acceleration = planarBlocks(p, accelOffsets, ACCEL_SCALE),
                rotationRate = planarBlocks(p, gyroOffsets, GYRO_SCALE),
            )
        }

        private fun planarBlocks(p: ByteArray, offsets: IntArray, scale: Double) = List(100) { i ->
            Vector3(i16(p, offsets[0] + i * 2) * scale, i16(p, offsets[1] + i * 2) * scale, i16(p, offsets[2] + i * 2) * scale)
        }
    }
}

/** Compact live IMU (0x33) on stream 5: 24-byte header + planar int16 accel/gyro. */
data class CompactImuPacket(val deviceTimestamp: Long, val acceleration: List<Vector3>, val rotationRate: List<Vector3>) {
    companion object {
        private const val HEADER = 24

        fun decode(p: ByteArray): CompactImuPacket? {
            if (p.size < HEADER || u8(p, 0) != PacketType.IMU) return null
            val ac = u16(p, 20)
            val gc = u16(p, 22)
            if (ac !in 1..100 || gc !in 1..100) return null
            if (p.size < HEADER + ac * 6 + gc * 6) return null
            return CompactImuPacket(
                u32(p, 4),
                planar(p, HEADER, ac, R10Record.ACCEL_SCALE),
                planar(p, HEADER + ac * 6, gc, R10Record.GYRO_SCALE),
            )
        }

        private fun planar(p: ByteArray, start: Int, count: Int, scale: Double): List<Vector3> {
            val stride = count * 2
            return List(count) { i ->
                Vector3(i16(p, start + i * 2) * scale, i16(p, start + stride + i * 2) * scale, i16(p, start + stride * 2 + i * 2) * scale)
            }
        }
    }
}

/** Standard Bluetooth Heart Rate Measurement (0x2A37). RR is in 1/1024 s units. */
data class HeartRateMeasurement(
    val bpm: Int,
    val contactSupported: Boolean,
    val contactDetected: Boolean,
    val energyExpended: Int?,
    val rrIntervalsMs: List<Double>,
) {
    companion object {
        fun parse(v: ByteArray): HeartRateMeasurement? {
            if (v.size < 2) return null
            val flags = u8(v, 0)
            var o = 1
            val bpm: Int
            if (flags and 0x01 != 0) {
                if (v.size < 3) return null
                bpm = u16(v, 1); o = 3
            } else {
                bpm = u8(v, 1); o = 2
            }
            val contactSupported = flags and 0x04 != 0
            val contactDetected = flags and 0x02 != 0
            var energy: Int? = null
            if (flags and 0x08 != 0 && o + 1 < v.size) { energy = u16(v, o); o += 2 }
            val rr = ArrayList<Double>()
            if (flags and 0x10 != 0) {
                while (o + 1 < v.size) { rr += u16(v, o) * 1000.0 / 1024.0; o += 2 }
            }
            return HeartRateMeasurement(bpm, contactSupported, contactDetected, energy, rr)
        }
    }
}

/** 0x30 events on stream 4. Event 0x3F (63) carries extended battery state. */
object StrapEvent {
    data class Battery(val percent: Int, val millivolts: Int, val charging: Boolean)

    /** Ported from AtriaStrapPowerPolicy.parseBatteryLevelEventFrame (full-frame offsets). */
    fun battery(frame: ByteArray): Battery? {
        if (frame.size <= 26 || frame[0] != 0xAA.toByte() || u8(frame, 4) != PacketType.EVENT || u8(frame, 6) != 0x03) return null
        val rawSoc = u16(frame, 17)
        val mv = u16(frame, 21)
        val charge = u8(frame, 26)
        if (rawSoc > 1000 || mv !in 3000..4300 || charge > 1) return null
        return Battery(Math.round(rawSoc / 10.0).toInt(), mv, charge == 1)
    }

    /** 2A19 values of 0/≤10/100 replay during reconnect; only accept them near the prior reading. */
    fun isBatterySentinel(level: Int) = level <= 10 || level >= 100

    /** 0x32 console log text (firmware ASCII), useful for diagnostics only. */
    fun consoleText(p: ByteArray): String? {
        if (p.isEmpty() || u8(p, 0) != PacketType.CONSOLE_LOG) return null
        return p.drop(1).filter { it in 0x20..0x7E }.map { it.toInt().toChar() }.joinToString("")
    }
}
