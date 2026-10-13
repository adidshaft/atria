package com.adidshaft.atria

import com.adidshaft.atria.ble.HistoryDrain
import com.adidshaft.atria.protocol.Cmd
import com.adidshaft.atria.protocol.CommandResponse
import com.adidshaft.atria.protocol.Crc
import com.adidshaft.atria.protocol.FrameCodec
import com.adidshaft.atria.protocol.FrameReassembler
import com.adidshaft.atria.protocol.HeartRateMeasurement
import com.adidshaft.atria.protocol.HistoricalRecord
import com.adidshaft.atria.protocol.HistoryCursorRange
import com.adidshaft.atria.protocol.HistoryMarker
import com.adidshaft.atria.protocol.StrapEvent
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

fun hex(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

class ProtocolTest {
    /** Fixtures copied verbatim from AtriaWhoop4HistoricalRecordDecoderTests (real WHOOP 4.0 archive). */
    private val capturedV24 = hex(
        "2f1805444931019a76316a983a80545e015402cd02e802000000000000f760ff80" +
            "1b153cd763c9bd3313b9bd9a21833f00008245d763c9bd3313b9bd9a21833f5a" +
            "02cc021904ca0261019009010c020c3000000000000001306a000000000000",
    )
    private val capturedV25 = hex(
        "2f1900eb530000d780316a88782400e6cc040039fecffcfcfce7fec000c0001801" +
            "2401d901e7016901a201340174003b002a00fdffa0ffc7ffbdff9fff6fff15ffd8" +
            "fe504b0f3d9009010000",
    )

    @Test fun crc32StandardCheckValue() {
        assertEquals(0xCBF43926L, Crc.crc32("123456789".toByteArray()))
        assertEquals(0L, Crc.crc32(ByteArray(0)))
    }

    @Test fun frameEncodingMatchesHarvardLayout() {
        val f = FrameCodec.command(0x10, Cmd.TOGGLE_REALTIME_HR, byteArrayOf(0x01))
        // AA | len=payload(4)+4=8 LE | crc8(len) | 23 10 03 01 | crc32
        assertEquals(0xAA.toByte(), f[0])
        assertEquals(8, f[1].toInt())
        assertEquals(0, f[2].toInt())
        assertEquals(Crc.crc8(8, 0).toByte(), f[3])
        assertArrayEquals(byteArrayOf(0x23, 0x10, 0x03, 0x01), f.copyOfRange(4, 8))
        assertEquals(12, f.size)
        assertArrayEquals(byteArrayOf(0x23, 0x10, 0x03, 0x01), FrameCodec.payloadOf(f))
    }

    @Test fun reassemblerJoinsFragmentsAndResyncs() {
        val a = FrameCodec.encode(byteArrayOf(0x24, 1, 2, 3, 4, 5))
        val b = FrameCodec.encode(byteArrayOf(0x31, 9, 1))
        val r = FrameReassembler()
        val stream = byteArrayOf(0x00, 0x13) + a + b
        val out = ArrayList<ByteArray>()
        stream.toList().chunked(5).forEach { out += r.feed(it.toByteArray(), "s5") }
        assertEquals(2, out.size)
        assertArrayEquals(a, out[0])
        assertArrayEquals(b, out[1])
    }

    @Test fun decodesCapturedV24() {
        val r = HistoricalRecord.decode(capturedV24)!!
        assertEquals(24, r.layout)
        assertEquals(0x01314944L, r.counter)
        assertEquals(1_781_626_522L, r.timestampSeconds)
        assertEquals(15_000, r.subsecond)
        assertEquals(84, r.heartRate)
        assertEquals(listOf(717, 744), r.rrIntervalsMs)
        assertEquals(-0.09833496063947678, r.gravity.x, 1e-7)
        assertEquals(-0.09036865085363388, r.gravity.y, 1e-7)
        assertEquals(1.0244629383087158, r.gravity.z, 1e-7)
        assertEquals(0.009100794792175293, r.motionScalar!!, 1e-7)
        assertEquals(27_184, r.motionTickCounter)
    }

    @Test fun decodesCapturedV25AsGravityOnly() {
        val r = HistoricalRecord.decode(capturedV25)!!
        assertEquals(25, r.layout)
        assertEquals(0x53EBL, r.counter)
        assertEquals(1_781_629_143L, r.timestampSeconds)
        assertNull(r.heartRate)
        assertTrue(r.rrIntervalsMs.isEmpty())
        assertEquals(15_631.0 / 16_384.0, r.gravity.x, 1e-7)
        assertEquals(2_448.0 / 16_384.0, r.gravity.y, 1e-7)
    }

    @Test fun commandResponseFixtures() {
        // AtriaWhoop4CommandResponse.historicalIMUUnsupportedFixtures
        val r = CommandResponse.parse(byteArrayOf(0x24, 0xef.toByte(), 0x69, 0x0a, 0x03, 0, 0, 0))!!
        assertEquals(0x69, r.opcode)
        assertEquals(0x0a, r.echoedRequestSequence)
        assertTrue(r.unsupported)
    }

    @Test fun heartRateMeasurementWithRr() {
        // flags: uint8 HR, contact supported+detected, RR present; 72 bpm; RR 1024 → 1000 ms
        val m = HeartRateMeasurement.parse(byteArrayOf(0x16, 72, 0x00, 0x04))!!
        assertEquals(72, m.bpm)
        assertTrue(m.contactDetected)
        assertEquals(1000.0, m.rrIntervalsMs.single(), 1e-9)
    }

    @Test fun historyMarkersAndAck() {
        assertTrue(HistoryMarker.parse(byteArrayOf(0x31, 5, 0x01)) is HistoryMarker.Start)
        val end = ByteArray(21).also { it[0] = 0x31; it[1] = 6; it[2] = 0x02; for (i in 13 until 21) it[i] = (i - 12).toByte() }
        val m = HistoryMarker.parse(end) as HistoryMarker.End
        assertArrayEquals(byteArrayOf(1, 1, 2, 3, 4, 5, 6, 7, 8), m.ackPayload)
        assertTrue(HistoryMarker.parse(byteArrayOf(0x31, 7, 0x03)) is HistoryMarker.Complete)
    }

    @Test fun dataRangePendingWrapsTheRing() {
        val p = ByteArray(66)
        p[0] = 0x24; p[2] = 0x22
        fun put(off: Int, v: Long) { for (i in 0..3) p[4 + off + i] = ((v shr (8 * i)) and 0xFF).toByte() }
        put(10, 100); put(14, 4000); put(22, 4096)
        val r = HistoryCursorRange.parse(p)!!
        assertEquals(100 + (4096 - 4000L), r.pendingRecords)
    }

    @Test fun drainPersistsBeforeAckAndRequestsNextPage() {
        val d = HistoryDrain()
        val first = d.start(0) as HistoryDrain.Action.Send
        assertEquals(Cmd.GET_DATA_RANGE, first.command)
        val range = HistoryCursorRange(10, 0, 4096, 10, null)
        val send = d.onRange(range, 1) as HistoryDrain.Action.Send
        assertEquals(Cmd.SEND_HISTORICAL_DATA, send.command)
        d.onMarker(HistoryMarker.Start(1), 2)
        d.onRecord(HistoricalRecord.decode(capturedV24)!!, 3)
        val persist = d.onMarker(HistoryMarker.End(1, 0, ByteArray(8) { 9 }), 4) as HistoryDrain.Action.Persist
        assertEquals(1, persist.records.size)
        assertEquals(Cmd.HISTORICAL_DATA_RESULT, (persist.then as HistoryDrain.Action.Send).command)
        assertEquals(Cmd.SEND_HISTORICAL_DATA, (d.onAckDelivered(5) as HistoryDrain.Action.Send).command)
        assertTrue(d.onMarker(HistoryMarker.Complete(2), 6) is HistoryDrain.Action.Finished)
    }

    @Test fun drainStopsWhenCaughtUp() {
        val d = HistoryDrain(); d.start(0)
        assertTrue(d.onRange(HistoryCursorRange(5, 5, 4096, 0, null), 1) is HistoryDrain.Action.Finished)
    }

    @Test fun drainTimeoutDropsUnackedPage() {
        val d = HistoryDrain(); d.start(0); d.onRange(HistoryCursorRange(10, 0, 4096, 10, null), 0)
        d.onRecord(HistoricalRecord.decode(capturedV24)!!, 1)
        val f = d.onTimeout(30_000) as HistoryDrain.Action.Finished
        assertEquals(0, f.rows)
    }

    @Test fun batteryEventUsesDeviceProvenOffsets() {
        val f = ByteArray(30); f[0] = 0xAA.toByte(); f[4] = 0x30; f[6] = 0x03
        f[17] = (723 and 0xFF).toByte(); f[18] = (723 shr 8).toByte()
        f[21] = (3900 and 0xFF).toByte(); f[22] = (3900 shr 8).toByte(); f[26] = 1
        val b = StrapEvent.battery(f)!!
        assertEquals(72, b.percent); assertEquals(3900, b.millivolts); assertTrue(b.charging)
        f[21] = 0; f[22] = 0
        assertNull(StrapEvent.battery(f))
        assertNotNull(Cmd.hapticPayload(2))
    }
}
