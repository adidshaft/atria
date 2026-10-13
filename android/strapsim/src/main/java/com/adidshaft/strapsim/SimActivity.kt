package com.adidshaft.strapsim

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelUuid
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import java.util.ArrayDeque
import java.util.UUID
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Simulated WHOOP 4.0 ("Harvard") for end-to-end tests of Atria's Android BLE code.
 * Protocol behaviour follows docs/WHOOP4_PROTOCOL_FINDINGS.md and the iOS decoders:
 * framing AA|len|crc8|payload|crc32, command responses 0x24, history 0x16 → 0x31 START,
 * 0x2F v24 rows, 0x31 END(token) and a pause until the 0x17 ACK, compact IMU 0x33 after 6A/01.
 */
@SuppressLint("MissingPermission")
class SimActivity : Activity() {
    companion object {
        const val TAG = "StrapSim"
        private fun std(s: String) = UUID.fromString("0000$s-0000-1000-8000-00805f9b34fb")
        val HR_SERVICE = std("180D"); val HR_MEASURE = std("2A37")
        val BATT_SERVICE = std("180F"); val BATT_LEVEL = std("2A19")
        val DIS_SERVICE = std("180A"); val FW_REV = std("2A26")
        val CCCD = std("2902")
        val STRAP = UUID.fromString("61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        val TX = UUID.fromString("61080002-8d6d-82b8-614a-1c8cb0f8dcc6")
        val RX = UUID.fromString("61080003-8d6d-82b8-614a-1c8cb0f8dcc6")
        val S4 = UUID.fromString("61080004-8d6d-82b8-614a-1c8cb0f8dcc6")
        val S5 = UUID.fromString("61080005-8d6d-82b8-614a-1c8cb0f8dcc6")
        const val PAGE = 60
        const val HISTORY_RECORDS = 180

        // Real v24 capture (AtriaWhoop4HistoricalRecordDecoderTests) used as the row template.
        val V24 = "2f1805444931019a76316a983a80545e015402cd02e802000000000000f760ff801b153cd763c9bd3313b9bd9a21833f00008245d763c9bd3313b9bd9a21833f5a02cc021904ca0261019009010c020c3000000000000001306a000000000000"
            .chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }

    private val worker = HandlerThread("sim").apply { start() }
    private val h = Handler(worker.looper)
    private lateinit var server: BluetoothGattServer
    private val subs = HashMap<UUID, MutableSet<BluetoothDevice>>()
    private val chars = HashMap<UUID, BluetoothGattCharacteristic>()
    private var mtu = 23
    private val outbox = ArrayDeque<Triple<BluetoothDevice, UUID, ByteArray>>()
    private var sending = false
    private var respSeq = 0
    private var readCursor = 0L
    private val writeCursor = HISTORY_RECORDS.toLong()
    private val historyStartUnix = System.currentTimeMillis() / 1000 - 3 * 3600
    private var imuOn = false
    private var imuT = 0
    private var tick = 0
    private lateinit var logView: TextView
    private val lines = ArrayDeque<String>()

    private fun log(msg: String) {
        Log.i(TAG, msg)
        runOnUiThread {
            lines.addFirst(msg); while (lines.size > 60) lines.removeLast()
            logView.text = lines.joinToString("\n")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        logView = TextView(this).apply { textSize = 11f; setPadding(24, 120, 24, 24) }
        setContentView(ScrollView(this).apply { addView(logView) })
        requestPermissions(arrayOf(android.Manifest.permission.BLUETOOTH_ADVERTISE, android.Manifest.permission.BLUETOOTH_CONNECT), 1)
        h.postDelayed({ start() }, 1500)
    }

    private fun start() {
        val bm = getSystemService(BluetoothManager::class.java)
        server = bm.openGattServer(this, cb)
        fun ch(u: UUID, props: Int, perms: Int) = BluetoothGattCharacteristic(u, props, perms).also { c ->
            if (props and (BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) c.addDescriptor(BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
            chars[u] = c
        }
        val notify = BluetoothGattCharacteristic.PROPERTY_NOTIFY
        val strap = BluetoothGattService(STRAP, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply {
            addCharacteristic(ch(TX, BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE, BluetoothGattCharacteristic.PERMISSION_WRITE))
            addCharacteristic(ch(RX, notify, 0)); addCharacteristic(ch(S4, notify, 0)); addCharacteristic(ch(S5, notify, 0))
        }
        val hr = BluetoothGattService(HR_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply { addCharacteristic(ch(HR_MEASURE, notify, 0)) }
        val batt = BluetoothGattService(BATT_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply { addCharacteristic(ch(BATT_LEVEL, notify or BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ)) }
        val dis = BluetoothGattService(DIS_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply { addCharacteristic(ch(FW_REV, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ)) }
        // addService is asynchronous: add sequentially from onServiceAdded.
        pendingServices.addAll(listOf(strap, hr, batt, dis))
        server.addService(pendingServices.poll())
        val adv = bm.adapter.bluetoothLeAdvertiser
        bm.adapter.name = "WHOOP 4C0SIM"
        adv.startAdvertising(
            AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).setConnectable(true).build(),
            AdvertiseData.Builder().addServiceUuid(ParcelUuid(STRAP)).build(),
            AdvertiseData.Builder().setIncludeDeviceName(true).build(),
            object : AdvertiseCallback() {
                override fun onStartSuccess(s: AdvertiseSettings) = log("advertising as WHOOP 4C0SIM")
                override fun onStartFailure(e: Int) = log("advertise failed $e")
            },
        )
        h.postDelayed(::second, 1000)
    }
    private val pendingServices = ArrayDeque<BluetoothGattService>()

    /** 1 Hz: standard HR with RR; 10 Hz compact IMU when 6A/01 is active. */
    private fun second() {
        tick++
        val bpm = 72 + (6 * sin(tick / 20.0)).roundToInt()
        val rr = (60_000.0 / bpm * 1024 / 1000).roundToInt()
        notifyAll(HR_MEASURE, byteArrayOf(0x16, bpm.toByte(), (rr and 0xFF).toByte(), (rr shr 8).toByte()))
        if (imuOn) repeat(10) { k -> h.postDelayed({ if (imuOn) sendImu() }, k * 100L) }
        h.postDelayed(::second, 1000)
    }

    private fun sendImu() {
        val p = ByteArray(24 + 60 + 60)
        p[0] = 0x33
        putU32(p, 4, System.currentTimeMillis() / 1000)
        p[20] = 10; p[22] = 10
        for (i in 0 until 10) {
            val t = (imuT++) / 100.0
            val g = 1.0 + 0.25 * sin(2 * PI * 1.8 * t) // ~108 steps/min walking signal
            putI16(p, 24 + i * 2, 0)                     // x
            putI16(p, 24 + 20 + i * 2, 0)                // y
            putI16(p, 24 + 40 + i * 2, (g * 4096).roundToInt()) // z
        }
        notifyAll(S5, frame(p))
    }

    private val cb = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) { pendingServices.poll()?.let { server.addService(it) } ?: log("services ready") }
        override fun onConnectionStateChange(d: BluetoothDevice, status: Int, newState: Int) {
            log("connection ${if (newState == BluetoothProfile.STATE_CONNECTED) "UP" else "DOWN"} ${d.address}")
            if (newState != BluetoothProfile.STATE_CONNECTED) { subs.values.forEach { it.remove(d) }; imuOn = false }
        }
        override fun onMtuChanged(d: BluetoothDevice, m: Int) { mtu = m; log("mtu $m") }
        override fun onCharacteristicReadRequest(d: BluetoothDevice, id: Int, off: Int, c: BluetoothGattCharacteristic) {
            val v = when (c.uuid) { BATT_LEVEL -> byteArrayOf(72); FW_REV -> "41.16.6.0".toByteArray(); else -> ByteArray(0) }
            server.sendResponse(d, id, BluetoothGatt.GATT_SUCCESS, 0, v.copyOfRange(minOf(off, v.size), v.size))
        }
        override fun onDescriptorWriteRequest(d: BluetoothDevice, id: Int, desc: BluetoothGattDescriptor, prep: Boolean, resp: Boolean, off: Int, v: ByteArray) {
            val on = v.isNotEmpty() && v[0].toInt() != 0
            val set = subs.getOrPut(desc.characteristic.uuid) { HashSet() }
            if (on) set += d else set -= d
            log("CCCD ${short(desc.characteristic.uuid)} ${if (on) "on" else "off"}")
            if (resp) server.sendResponse(d, id, BluetoothGatt.GATT_SUCCESS, 0, null)
        }
        override fun onCharacteristicWriteRequest(d: BluetoothDevice, id: Int, c: BluetoothGattCharacteristic, prep: Boolean, resp: Boolean, off: Int, v: ByteArray) {
            if (resp) server.sendResponse(d, id, BluetoothGatt.GATT_SUCCESS, 0, null)
            if (c.uuid == TX) h.post { onCommand(v) }
        }
        override fun onNotificationSent(d: BluetoothDevice, status: Int) { h.post { sending = false; pump() } }
    }

    private fun onCommand(f: ByteArray) {
        if (f.size < 11 || f[0] != 0xAA.toByte()) return log("bad frame")
        val len = u16(f, 1)
        val payload = f.copyOfRange(4, len)
        if (crc32(payload) != u32(f, len)) return log("CRC mismatch")
        val seq = payload[1].toInt() and 0xFF
        val cmd = payload[2].toInt() and 0xFF
        val body = payload.copyOfRange(3, payload.size)
        log("cmd %02x %s".format(cmd, body.joinToString("") { "%02x".format(it) }))
        when (cmd) {
            0x22 -> { // GET_DATA_RANGE: data[10]=write, data[14]=read, data[22]=capacity
                val data = ByteArray(62); putU32(data, 10, writeCursor); putU32(data, 14, readCursor); putU32(data, 22, 4096); putU32(data, 58, System.currentTimeMillis() / 1000)
                respond(seq, cmd, data)
            }
            0x0B -> { val d = ByteArray(5); d[0] = 1; putU32(d, 1, System.currentTimeMillis() / 1000 - 7); respondRaw(seq, cmd, d) }
            0x16 -> sendHistoryPage()
            0x17 -> { readCursor = minOf(writeCursor, readCursor + PAGE); log("ACK → read cursor $readCursor"); respond(seq, cmd, byteArrayOf()) }
            0x6A -> { imuOn = body.firstOrNull()?.toInt() == 1; log("IMU ${if (imuOn) "ON" else "OFF"}"); respond(seq, cmd, byteArrayOf()) }
            0x4F -> { log("BUZZ x${body.getOrNull(1) ?: 0}"); respond(seq, cmd, byteArrayOf()) }
            else -> respond(seq, cmd, byteArrayOf())
        }
    }

    private fun sendHistoryPage() {
        if (readCursor >= writeCursor) { notifyAll(S5, frame(byteArrayOf(0x31, 9, 0x03))); log("history COMPLETE"); return }
        notifyAll(S5, frame(byteArrayOf(0x31, 1, 0x01)))
        val n = minOf(PAGE.toLong(), writeCursor - readCursor).toInt()
        for (i in 0 until n) {
            val idx = readCursor + i
            val r = V24.copyOf()
            putU32(r, 3, 0x01314944L + idx)
            putU32(r, 7, historyStartUnix + idx * 60)       // one row per minute, 3 h ago onward
            r[17] = (58 + (idx % 10)).toByte()               // HR
            notifyAll(S5, frame(r))
        }
        val end = ByteArray(21); end[0] = 0x31; end[1] = 2; end[2] = 0x02; putU32(end, 9, readCursor); for (k in 0 until 8) end[13 + k] = (0xA0 + k).toByte()
        notifyAll(S5, frame(end))
        log("history page ${readCursor}..${readCursor + n} sent, awaiting ACK")
    }

    private fun respond(seq: Int, cmd: Int, data: ByteArray) = respondRaw(seq, cmd, byteArrayOf(1) + data)
    private fun respondRaw(seq: Int, cmd: Int, dataWithStatus: ByteArray) {
        respSeq = (respSeq + 1) and 0xFF
        notifyAll(RX, frame(byteArrayOf(0x24, respSeq.toByte(), cmd.toByte(), seq.toByte()) + dataWithStatus))
    }

    private fun notifyAll(u: UUID, value: ByteArray) {
        val targets = subs[u] ?: return
        val chunk = maxOf(20, mtu - 3)
        for (d in targets) { var o = 0; while (o < value.size) { outbox += Triple(d, u, value.copyOfRange(o, minOf(value.size, o + chunk))); o += chunk } }
        pump()
    }

    private fun pump() {
        if (sending) return
        val (d, u, v) = outbox.poll() ?: return
        sending = true
        val r = server.notifyCharacteristicChanged(d, chars.getValue(u), false, v)
        if (r != BluetoothGatt.GATT_SUCCESS) { sending = false; h.postDelayed(::pump, 20) }
    }

    // ---- framing ----
    private fun frame(p: ByteArray): ByteArray {
        val len = p.size + 4
        val lo = (len and 0xFF).toByte(); val hi = (len shr 8).toByte()
        val c = crc32(p)
        return byteArrayOf(0xAA.toByte(), lo, hi, crc8(lo, hi)) + p + byteArrayOf((c and 0xFF).toByte(), (c shr 8 and 0xFF).toByte(), (c shr 16 and 0xFF).toByte(), (c shr 24 and 0xFF).toByte())
    }
    private fun crc8(vararg b: Byte): Byte { var c = 0; for (x in b) { c = c xor (x.toInt() and 0xFF); repeat(8) { c = if (c and 0x80 != 0) (c shl 1 xor 7) and 0xFF else (c shl 1) and 0xFF } }; return c.toByte() }
    private fun crc32(b: ByteArray): Long { val z = java.util.zip.CRC32(); z.update(b); return z.value }
    private fun u16(b: ByteArray, o: Int) = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)
    private fun u32(b: ByteArray, o: Int): Long = (0..3).fold(0L) { a, i -> a or ((b[o + i].toLong() and 0xFF) shl (8 * i)) }
    private fun putU32(b: ByteArray, o: Int, v: Long) { for (i in 0..3) b[o + i] = ((v shr (8 * i)) and 0xFF).toByte() }
    private fun putI16(b: ByteArray, o: Int, v: Int) { b[o] = (v and 0xFF).toByte(); b[o + 1] = ((v shr 8) and 0xFF).toByte() }
    private fun short(u: UUID) = u.toString().substring(4, 8)
}
