package com.adidshaft.atria.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelUuid
import com.adidshaft.atria.data.Repository
import com.adidshaft.atria.protocol.ClockResponse
import com.adidshaft.atria.protocol.Cmd
import com.adidshaft.atria.protocol.CommandResponse
import com.adidshaft.atria.protocol.CompactImuPacket
import com.adidshaft.atria.protocol.FrameCodec
import com.adidshaft.atria.protocol.FrameReassembler
import com.adidshaft.atria.protocol.HeartRateMeasurement
import com.adidshaft.atria.protocol.HistoricalRecord
import com.adidshaft.atria.protocol.HistoryCursorRange
import com.adidshaft.atria.protocol.HistoryMarker
import com.adidshaft.atria.protocol.PacketType
import com.adidshaft.atria.protocol.R10Record
import com.adidshaft.atria.protocol.StrapEvent
import com.adidshaft.atria.protocol.WhoopUuids
import com.adidshaft.atria.protocol.toHex
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.util.ArrayDeque
import java.util.UUID

enum class LinkStatus { BLUETOOTH_OFF, NO_PERMISSION, UNPAIRED, SCANNING, CONNECTING, CONNECTED, DISCONNECTED }

data class DiscoveredStrap(val address: String, val name: String, val rssi: Int)

data class LiveState(
    val status: LinkStatus = LinkStatus.UNPAIRED,
    val heartRate: Int = 0,
    val heartRateAt: Long = 0,
    val rrMs: List<Double> = emptyList(),
    val battery: Int? = null,
    val charging: Boolean = false,
    val firmware: String? = null,
    val onWrist: Boolean = true,
    val imuLive: Boolean = false,
    val sessionSteps: Int = 0,
    val drainActive: Boolean = false,
    val drainRows: Int = 0,
    val pendingRecords: Long? = null,
    val packets: Long = 0,
    val lastError: String? = null,
    val discovered: List<DiscoveredStrap> = emptyList(),
) {
    val hrFresh get() = heartRate > 0 && System.currentTimeMillis() - heartRateAt < 15_000
}

/**
 * Android replacement for the CoreBluetooth transport in AtriaBLEManager.
 *
 * iOS → Android mapping:
 *  - CBCentralManager state restoration + pending connect → `connectGatt(autoConnect = true)`
 *    held by a foreground service (connectedDevice type) and CompanionDeviceManager presence.
 *  - CoreBluetooth's implicit op queue → explicit one-at-a-time GATT queue (Android drops
 *    concurrent ops silently).
 *  - CBErrorDomain 6 / bluetoothd wedges → GATT 133/8 handling with close+backoff reconnect.
 *  - 185-byte iOS ATT MTU → explicit requestMtu(247).
 */
@SuppressLint("MissingPermission")
class StrapManager(private val context: Context, private val repo: Repository) {
    private val thread = HandlerThread("atria-ble").apply { start() }
    private val handler = Handler(thread.looper)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val bluetooth = context.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = bluetooth?.adapter

    private val _state = MutableStateFlow(LiveState())
    val state: StateFlow<LiveState> = _state.asStateFlow()

    private var gatt: BluetoothGatt? = null
    private var targetAddress: String? = null
    private var wantConnected = false
    private var reconnectDelayMs = 2_000L
    /** Scan results keep the address type, which a bare MAC string loses. */
    private val scanned = HashMap<String, BluetoothDevice>()
    private var addressType: Int? = null
    /** Direct (autoConnect=false) attempts since the last successful link; then fall back to autoConnect. */
    private var directAttempts = 0
    private var everConnectedThisLink = false
    private var cmdSeq = 0
    private val reassembler = FrameReassembler()
    private val motion = MotionAccumulator()
    private val drain = HistoryDrain()
    private var drainRequested = false
    private var lastDrainAt = 0L
    private var imuEnabled = false
    private var allDayMotion = true
    private var clockOffsetSeconds = 0L
    private val liveBuffer = LiveSampleBuffer(repo)
    private var rawPackets = 0L
    /** Rolling raw-frame log for the developer screen (AtriaIMUDiagnosticTransport evidence). */
    private val frameLog = java.util.ArrayDeque<String>()
    fun recentFrames(): List<String> = synchronized(frameLog) { frameLog.toList() }
    var lastClockDeviceUnix: Long? = null
        private set

    // ---- GATT op queue ------------------------------------------------------------------
    private sealed interface Op {
        data class Write(val uuid: UUID, val value: ByteArray, val type: Int) : Op
        data class Read(val uuid: UUID) : Op
        data class Notify(val uuid: UUID, val enable: Boolean) : Op
        data object Mtu : Op
    }
    private val ops = ArrayDeque<Op>()
    private var opInFlight: Op? = null
    private var opStartedAt = 0L

    var onHeartRate: ((Int, List<Double>) -> Unit)? = null
    var onConnectionChanged: ((LinkStatus) -> Unit)? = null

    private val btReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_OFF -> handler.post { teardown(); setStatus(LinkStatus.BLUETOOTH_OFF) }
                BluetoothAdapter.STATE_ON -> handler.post { if (wantConnected) connectInternal() }
            }
        }
    }

    init {
        context.registerReceiver(btReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        handler.postDelayed(::watchdog, 10_000)
        scope.launch {
            val s = repo.settings.currentStrap()
            clockOffsetSeconds = s.clockOffsetSeconds
            allDayMotion = repo.settings.current().allDayMotion
            _state.update { it.copy(battery = s.batteryLevel, firmware = s.firmware, pendingRecords = s.pendingRecords) }
        }
    }

    // ---- public API ----------------------------------------------------------------------
    fun hasPermissions(): Boolean = Permissions.hasBluetooth(context)

    fun startScan() = handler.post {
        val a = adapter
        if (!hasPermissions()) return@post setStatus(LinkStatus.NO_PERMISSION)
        if (a == null || !a.isEnabled) return@post setStatus(LinkStatus.BLUETOOTH_OFF)
        _state.update { it.copy(discovered = emptyList()) }
        setStatus(LinkStatus.SCANNING)
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(WhoopUuids.strapService)).build(),
            ScanFilter.Builder().setServiceUuid(ParcelUuid(WhoopUuids.heartRateService)).build(),
        )
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        runCatching { a.bluetoothLeScanner?.startScan(filters, settings, scanCallback) }
        handler.postDelayed({ stopScan() }, 20_000)
    }

    fun stopScan() = handler.post {
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        if (_state.value.status == LinkStatus.SCANNING) setStatus(if (targetAddress == null) LinkStatus.UNPAIRED else LinkStatus.DISCONNECTED)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val name = result.scanRecord?.deviceName ?: result.device.name ?: "Strap"
            scanned[result.device.address] = result.device
            val found = DiscoveredStrap(result.device.address, name, result.rssi)
            _state.update { s -> s.copy(discovered = (s.discovered.filter { it.address != found.address } + found).sortedByDescending { it.rssi }) }
        }
        override fun onScanFailed(errorCode: Int) { _state.update { it.copy(lastError = "scan_failed_$errorCode") } }
    }

    /** Pair with [address] (persisted) and hold a standing auto-connection until [forget]. */
    fun connect(address: String, name: String? = null) = handler.post {
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        targetAddress = address
        wantConnected = true
        directAttempts = 0
        addressType = scanned[address]?.let(::addressTypeOf) ?: inferAddressType(address)
        val type = addressType
        if (name != null) pairedName = name
        scope.launch { repo.settings.updateStrap { it.copy(pairedAddress = address, pairedName = name ?: it.pairedName, addressType = type, capturePaused = false) } }
        connectInternal()
    }

    /** Resume the saved strap (service start, boot, CDM presence). */
    fun resume() = handler.post {
        if (gatt != null) return@post
        val strapState = runBlocking { repo.settings.currentStrap() }
        if (strapState.capturePaused) return@post setStatus(LinkStatus.DISCONNECTED)
        val saved = strapState.pairedAddress ?: return@post setStatus(LinkStatus.UNPAIRED)
        addressType = strapState.addressType ?: inferAddressType(saved)
        targetAddress = saved
        wantConnected = true
        connectInternal()
    }

    fun disconnect() = handler.post { wantConnected = false; stopReconnectScan(); teardown(); setStatus(LinkStatus.DISCONNECTED) }

    fun forget() = handler.post {
        wantConnected = false
        stopReconnectScan()
        teardown()
        targetAddress = null
        scope.launch { repo.settings.updateStrap { com.adidshaft.atria.data.StrapState() } }
        setStatus(LinkStatus.UNPAIRED)
    }

    /** Buzz the strap motor (0x4F pattern 2). */
    fun haptic(pulses: Int = 2) = handler.post { sendCommand(Cmd.RUN_HAPTICS_PATTERN, Cmd.hapticPayload(pulses)) }

    /** Start an oldest-first history catch-up slice (user "Sync now" or scheduled worker). */
    fun requestHistorySync() = handler.post {
        drainRequested = true
        if (_state.value.status == LinkStatus.CONNECTED) startDrainIfIdle()
    }

    fun setAllDayMotion(enabled: Boolean) = handler.post {
        allDayMotion = enabled
        if (_state.value.status == LinkStatus.CONNECTED) setImu(enabled)
    }

    /** Workout lease: make sure compact IMU is on for the duration regardless of the all-day choice. */
    fun setWorkoutMotion(active: Boolean) = handler.post {
        if (active) { motion.resetSession(); setImu(true) } else if (!allDayMotion) setImu(false)
    }

    fun sessionSteps() = motion.sessionSteps

    /**
     * Developer diagnostics: an explicit allowlist of read-only / reversible commands
     * (GET_CLOCK, GET_DATA_RANGE, GET_BATTERY, IMU on/off). Mutating history commands
     * (16/17 drain, 19 trim) are never exposed here.
     */
    fun diagnosticCommand(command: Int, body: ByteArray) = handler.post {
        val allowed = command in setOf(Cmd.GET_CLOCK, Cmd.GET_DATA_RANGE, Cmd.GET_BATTERY_LEVEL, Cmd.TOGGLE_IMU_MODE, Cmd.TOGGLE_REALTIME_HR)
        if (!allowed || _state.value.status != LinkStatus.CONNECTED) return@post
        if (command == Cmd.TOGGLE_IMU_MODE) imuEnabled = body.firstOrNull()?.toInt() == 1
        sendCommand(command, body)
    }

    /** Clock repair: write wall time to the strap (user-approved, mutating). */
    fun syncClock() = handler.post { sendCommand(Cmd.SET_CLOCK, Cmd.setClockPayload(System.currentTimeMillis() / 1000)) }

    // ---- connection lifecycle ----------------------------------------------------------
    private fun connectInternal() {
        val a = adapter
        if (!hasPermissions()) return setStatus(LinkStatus.NO_PERMISSION)
        if (a == null || !a.isEnabled) return setStatus(LinkStatus.BLUETOOTH_OFF)
        val address = targetAddress ?: return setStatus(LinkStatus.UNPAIRED)
        if (gatt != null) return
        // A device rebuilt from a MAC string defaults to the PUBLIC address type; with a random
        // address that fails instantly (GATT 135). Prefer the scanned device, else rebuild with type.
        val device: BluetoothDevice = scanned[address]
            ?: (if (Build.VERSION.SDK_INT >= 33) runCatching { a.getRemoteLeDevice(address, addressType ?: BluetoothDevice.ADDRESS_TYPE_RANDOM) }.getOrNull() else null)
            ?: runCatching { a.getRemoteDevice(address) }.getOrNull() ?: return setStatus(LinkStatus.UNPAIRED)
        setStatus(LinkStatus.CONNECTING)
        // Direct connects are fast; after two misses scheduleReconnect() hands over to a filtered
        // reconnect scan, the Android stand-in for a CoreBluetooth pending connection.
        stopReconnectScan()
        val auto = false
        directAttempts++
        everConnectedThisLink = false
        log("link", "connect $address auto=$auto type=${addressType ?: "?"}")
        gatt = device.connectGatt(context, auto, callback, BluetoothDevice.TRANSPORT_LE)
    }

    private fun teardown() {
        ops.clear(); opInFlight = null
        if (drain.isActive) drain.abort("disconnect")
        _state.update { it.copy(drainActive = false, imuLive = false) }
        imuEnabled = false
        reassembler.reset()
        motion.flush()?.let { m -> scope.launch { repo.insertMotion(listOf(m)) } }
        liveBuffer.flush()
        runCatching { gatt?.disconnect() }
        runCatching { gatt?.close() }
        gatt = null
    }

    /**
     * Reconnect scan: after direct connects fail, look for the strap by service UUID. Android's
     * autoConnect cannot follow a rotated private address (CoreBluetooth hides this behind its
     * peripheral identifier), so a strap seen again under a new address but the same name and
     * WHOOP service is adopted. Filtered scans keep running with the screen off under the FGS.
     */
    private var reconnectScanning = false
    private var pairedName: String? = null

    private val reconnectScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val address = result.device.address
            val name = result.scanRecord?.deviceName ?: result.device.name
            val target = targetAddress ?: return
            val sameDevice = address == target
            val rotated = !sameDevice && name != null && name == pairedName
            if (!sameDevice && !rotated) return
            handler.post {
                stopReconnectScan()
                if (gatt != null) return@post
                scanned[address] = result.device
                if (rotated) {
                    log("link", "strap address rotated $target → $address")
                    targetAddress = address
                    addressType = addressTypeOf(result.device) ?: inferAddressType(address)
                    val type = addressType
                    scope.launch { repo.settings.updateStrap { it.copy(pairedAddress = address, addressType = type) } }
                }
                directAttempts = 0
                connectInternal()
            }
        }
    }

    private fun startReconnectScan() {
        if (reconnectScanning || !hasPermissions()) return
        val scanner = adapter?.bluetoothLeScanner ?: return
        if (pairedName == null) pairedName = runBlocking { repo.settings.currentStrap().pairedName }
        reconnectScanning = true
        log("link", "reconnect scan")
        runCatching {
            scanner.startScan(
                listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(WhoopUuids.strapService)).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build(),
                reconnectScanCallback,
            )
        }.onFailure { reconnectScanning = false }
    }

    private fun stopReconnectScan() {
        if (!reconnectScanning) return
        reconnectScanning = false
        runCatching { adapter?.bluetoothLeScanner?.stopScan(reconnectScanCallback) }
    }

    private fun scheduleReconnect() {
        if (!wantConnected) return
        // Two direct attempts failed: find the strap by scanning instead of a blind autoConnect.
        if (directAttempts >= 2) { startReconnectScan(); return }
        val delay = reconnectDelayMs
        reconnectDelayMs = (reconnectDelayMs * 2).coerceAtMost(60_000)
        handler.postDelayed({ if (wantConnected && gatt == null) connectInternal() }, delay)
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = handler.post {
            if (g != gatt) return@post
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                log("link", "connected")
                reconnectDelayMs = 2_000
                directAttempts = 0
                everConnectedThisLink = true
                ops.clear(); opInFlight = null
                enqueue(Op.Mtu)
                runCatching { g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_BALANCED) }
            } else {
                log("link", "disconnected status=$status")
                // After a real link drops, try fast direct reconnects again before falling back.
                if (everConnectedThisLink) directAttempts = 0
                val wasConnected = _state.value.status == LinkStatus.CONNECTED
                teardown()
                setStatus(LinkStatus.DISCONNECTED)
                if (wasConnected) scope.launch { repo.settings.updateStrap { it.copy(lastConnectedAt = System.currentTimeMillis()) } }
                // 133/8/19/22 are routine on Android: close and retry with backoff.
                scheduleReconnect()
            }
        }.let { }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = handler.post {
            log("link", "mtu=$mtu")
            completeOp()
            if (!g.discoverServices()) scheduleReconnect()
        }.let { }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = handler.post {
            if (status != BluetoothGatt.GATT_SUCCESS) { log("link", "discovery failed $status"); teardown(); scheduleReconnect(); return@post }
            onReady(g)
        }.let { }

        @Deprecated("API < 33")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") val v = c.value ?: return
            onNotify(c.uuid, v.copyOf())
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) = onNotify(c.uuid, value)

        @Deprecated("API < 33")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION") val v = c.value ?: ByteArray(0)
            handler.post { onRead(c.uuid, v.copyOf(), status); completeOp() }
        }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            handler.post { onRead(c.uuid, value, status); completeOp() }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            handler.post {
                if (status != BluetoothGatt.GATT_SUCCESS) log("tx", "write failed $status")
                completeOp()
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            handler.post {
                if (status == BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION || status == BluetoothGatt.GATT_INSUFFICIENT_ENCRYPTION) {
                    log("link", "bonding required"); g.device.createBond()
                }
                completeOp()
            }
        }
    }

    private fun onReady(g: BluetoothGatt) {
        setStatus(LinkStatus.CONNECTED)
        scope.launch { repo.settings.updateStrap { it.copy(lastConnectedAt = System.currentTimeMillis()) } }
        enqueue(Op.Notify(WhoopUuids.heartRateMeasurement, true))
        enqueue(Op.Notify(WhoopUuids.batteryLevel, true))
        enqueue(Op.Notify(WhoopUuids.strapRX, true))
        enqueue(Op.Notify(WhoopUuids.strapStream5, true))
        enqueue(Op.Notify(WhoopUuids.strapStream4, true))
        enqueue(Op.Read(WhoopUuids.batteryLevel))
        enqueue(Op.Read(WhoopUuids.firmwareRevision))
        handler.postDelayed({
            if (_state.value.status != LinkStatus.CONNECTED) return@postDelayed
            sendCommand(Cmd.GET_CLOCK, byteArrayOf(0x00))
            if (allDayMotion) setImu(true)
            if (drainRequested || System.currentTimeMillis() - lastDrainAt > 30 * 60_000) startDrainIfIdle()
        }, 1_500)
    }

    // ---- inbound -------------------------------------------------------------------------
    private fun onRead(uuid: UUID, v: ByteArray, status: Int) {
        if (status != BluetoothGatt.GATT_SUCCESS) return
        when (uuid) {
            WhoopUuids.batteryLevel -> v.firstOrNull()?.let { acceptBattery(it.toInt() and 0xFF, null) }
            WhoopUuids.firmwareRevision -> {
                val fw = String(v).trim()
                _state.update { it.copy(firmware = fw) }
                scope.launch { repo.settings.updateStrap { it.copy(firmware = fw) } }
            }
        }
    }

    private fun onNotify(uuid: UUID, value: ByteArray) {
        rawPackets++
        when (uuid) {
            WhoopUuids.heartRateMeasurement -> HeartRateMeasurement.parse(value)?.let(::onHeartRateMeasurement)
            WhoopUuids.batteryLevel -> value.firstOrNull()?.let { b -> handler.post { acceptBattery(b.toInt() and 0xFF, null) } }
            else -> {
                val frames = reassembler.feed(value, uuid.toString())
                for (f in frames) handleFrame(f)
            }
        }
    }

    private fun onHeartRateMeasurement(m: HeartRateMeasurement) {
        val now = System.currentTimeMillis()
        val offWrist = m.contactSupported && !m.contactDetected
        if (m.bpm <= 0 || offWrist) { _state.update { it.copy(onWrist = !offWrist) }; return }
        _state.update { it.copy(heartRate = m.bpm, heartRateAt = now, rrMs = m.rrIntervalsMs, onWrist = true, packets = rawPackets) }
        liveBuffer.add(now, m.bpm, m.rrIntervalsMs)
        onHeartRate?.invoke(m.bpm, m.rrIntervalsMs)
    }

    private fun handleFrame(frame: ByteArray) {
        synchronized(frameLog) {
            frameLog.addFirst("${java.time.LocalTime.now().withNano(0)} %02x len=${frame.size} ${frame.copyOfRange(0, minOf(frame.size, 40)).toHex()}".format(if (frame.size > 4) frame[4].toInt() and 0xFF else 0))
            while (frameLog.size > 100) frameLog.removeLast()
        }
        val payload = FrameCodec.payloadOf(frame) ?: return
        val now = System.currentTimeMillis()
        when (payload[0].toInt() and 0xFF) {
            PacketType.COMMAND_RESPONSE -> handler.post { onCommandResponse(payload, now) }
            PacketType.HISTORICAL -> HistoricalRecord.decode(payload)?.let { r -> handler.post { drain.onRecord(r, now) } }
            PacketType.METADATA -> HistoryMarker.parse(payload)?.let { mk -> handler.post { drain.onMarker(mk, now)?.let(::perform) } }
            PacketType.IMU -> CompactImuPacket.decode(payload)?.let { p ->
                _state.update { it.copy(imuLive = true) }
                val minutes = motion.ingest(p.acceleration, now, if (p.acceleration.size <= 20) 10.0 else 100.0)
                _state.update { it.copy(sessionSteps = motion.sessionSteps) }
                if (minutes.isNotEmpty()) scope.launch { repo.insertMotion(minutes) }
            }
            PacketType.REALTIME_RAW -> R10Record.decode(payload)?.let { r ->
                val minutes = motion.ingest(r.acceleration, now)
                if (r.skinTemperatureRaw in 200..450) scope.launch { repo.insertSkinTemp(now, r.skinTemperatureCelsius) }
                if (minutes.isNotEmpty()) scope.launch { repo.insertMotion(minutes) }
                _state.update { it.copy(imuLive = true, sessionSteps = motion.sessionSteps) }
            }
            PacketType.EVENT -> StrapEvent.battery(frame)?.let { b -> handler.post { acceptBattery(b.percent, b.charging) } }
            PacketType.CONSOLE_LOG -> StrapEvent.consoleText(payload)?.let { log("strap", it.take(120)) }
        }
    }

    private fun onCommandResponse(payload: ByteArray, now: Long) {
        val r = CommandResponse.parse(payload) ?: return
        when (r.opcode) {
            Cmd.GET_DATA_RANGE -> HistoryCursorRange.parse(payload)?.let { range ->
                _state.update { it.copy(pendingRecords = range.pendingRecords) }
                scope.launch { repo.settings.updateStrap { it.copy(pendingRecords = range.pendingRecords) } }
                drain.onRange(range, now)?.let(::perform)
            }
            Cmd.GET_CLOCK -> ClockResponse.deviceUnix(payload, now / 1000)?.let { device ->
                lastClockDeviceUnix = device
                clockOffsetSeconds = now / 1000 - device
                scope.launch { repo.settings.updateStrap { it.copy(clockOffsetSeconds = clockOffsetSeconds) } }
            }
            Cmd.TOGGLE_IMU_MODE -> log("imu", "6A ack status=${r.status}")
        }
    }

    private fun acceptBattery(level: Int, charging: Boolean?) {
        val prev = _state.value.battery
        // Sentinel replays (0/≤10/100) during reconnect are only believed near the prior value.
        if (StrapEvent.isBatterySentinel(level) && prev != null && kotlin.math.abs(prev - level) > 5) return
        if (level !in 0..100) return
        val nowCharging = charging ?: _state.value.charging
        _state.update { it.copy(battery = level, charging = nowCharging) }
        scope.launch {
            repo.settings.updateStrap { s ->
                val hours = if (nowCharging && !s.charging) (s.chargeHours + java.time.LocalTime.now().hour).takeLast(20) else s.chargeHours
                s.copy(batteryLevel = level, batteryAt = System.currentTimeMillis(), charging = nowCharging, chargeHours = hours)
            }
        }
    }

    // ---- history drain -------------------------------------------------------------------
    private fun startDrainIfIdle() {
        if (drain.isActive || _state.value.status != LinkStatus.CONNECTED) return
        drainRequested = false
        lastDrainAt = System.currentTimeMillis()
        _state.update { it.copy(drainActive = true, drainRows = 0) }
        log("drain", "start")
        runCatching { gatt?.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH) }
        perform(drain.start(System.currentTimeMillis()))
    }

    private fun perform(action: HistoryDrain.Action) {
        when (action) {
            is HistoryDrain.Action.Send -> sendCommand(action.command, action.payload)
            is HistoryDrain.Action.Persist -> {
                val offset = clockOffsetSeconds
                val records = action.records
                scope.launch {
                    repo.insertHistory(records, offset) // durable before ACK
                    handler.post {
                        _state.update { it.copy(drainRows = drain.rows) }
                        perform(action.then)
                        if (action.then is HistoryDrain.Action.Send) {
                            // ACK sent; ask for the next page shortly after.
                            handler.postDelayed({ if (drain.isActive) perform(drain.onAckDelivered(System.currentTimeMillis())) }, 250)
                        }
                    }
                }
            }
            is HistoryDrain.Action.Finished -> {
                log("drain", "finished ${action.reason} pages=${action.pages} rows=${action.rows}")
                _state.update { it.copy(drainActive = false) }
                runCatching { gatt?.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_BALANCED) }
                sendCommand(Cmd.GET_DATA_RANGE, byteArrayOf(0x00))
                scope.launch {
                    val now = System.currentTimeMillis()
                    val pending = _state.value.pendingRecords ?: 0
                    repo.settings.updateStrap {
                        val zeros = if (action.rows > 0 || pending == 0L) 0 else it.consecutiveZeroProgressSlices + 1
                        val since = if (pending == 0L) null else it.backlogSince ?: now
                        val stalled = pending > 0 && (zeros >= TERMINAL_STALL_SLICES || (since != null && now - since >= TERMINAL_STALL_WINDOW_MS && action.rows == 0))
                        it.copy(
                            lastHistorySyncAt = now, historyRecordsSaved = it.historyRecordsSaved + action.rows,
                            consecutiveZeroProgressSlices = zeros, backlogSince = since,
                            lastProductiveSliceAt = if (action.rows > 0) now else it.lastProductiveSliceAt,
                            parkedAt = if (stalled) (it.parkedAt ?: now) else if (pending == 0L || action.rows > 0) null else it.parkedAt,
                        )
                    }
                    if (action.rows > 0) repo.onHistoryIngested()
                }
            }
        }
    }

    private fun setImu(enable: Boolean) {
        if (enable == imuEnabled) return
        imuEnabled = enable
        // Physically proven compact-IMU order: 03/01 (realtime HR) → 6A/01. Never 51 or 3F on
        // the all-day path: both provoked controller timeouts on device.
        if (enable) {
            sendCommand(Cmd.TOGGLE_REALTIME_HR, byteArrayOf(0x01))
            sendCommand(Cmd.TOGGLE_IMU_MODE, byteArrayOf(0x01))
        } else {
            sendCommand(Cmd.TOGGLE_IMU_MODE, byteArrayOf(0x00))
            _state.update { it.copy(imuLive = false) }
        }
    }

    // ---- outbound ------------------------------------------------------------------------
    private fun sendCommand(command: Int, body: ByteArray) {
        cmdSeq = (cmdSeq + 1) and 0xFF
        val frame = FrameCodec.command(cmdSeq, command, body)
        log("tx", "%02x %s".format(command, body.toHex()))
        enqueue(Op.Write(WhoopUuids.strapTX, frame, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT))
    }

    private fun enqueue(op: Op) { ops.add(op); pump() }

    private fun completeOp() { opInFlight = null; pump() }

    private fun pump() {
        if (opInFlight != null) return
        val g = gatt ?: return
        val op = ops.poll() ?: return
        opInFlight = op
        opStartedAt = System.currentTimeMillis()
        val ok = when (op) {
            Op.Mtu -> g.requestMtu(247)
            is Op.Read -> characteristic(g, op.uuid)?.let { g.readCharacteristic(it) } ?: false
            is Op.Write -> characteristic(g, op.uuid)?.let { c -> write(g, c, op.value, op.type) } ?: false
            is Op.Notify -> characteristic(g, op.uuid)?.let { c ->
                g.setCharacteristicNotification(c, op.enable)
                val d = c.getDescriptor(WhoopUuids.clientCharacteristicConfig)
                if (d == null) false else {
                    val v = if (!op.enable) BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                    else if (c.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0 && c.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                    else BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(d, v) == BluetoothGatt.GATT_SUCCESS
                    else { @Suppress("DEPRECATION") d.value = v; @Suppress("DEPRECATION") g.writeDescriptor(d) }
                }
            } ?: false
        }
        if (!ok) { opInFlight = null; handler.post(::pump) }
    }

    private fun write(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, type: Int): Boolean =
        if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(c, value, type) == BluetoothGatt.GATT_SUCCESS
        else { @Suppress("DEPRECATION") c.writeType = type; @Suppress("DEPRECATION") c.value = value; @Suppress("DEPRECATION") g.writeCharacteristic(c) }

    private fun characteristic(g: BluetoothGatt, uuid: UUID): BluetoothGattCharacteristic? =
        g.services.asSequence().mapNotNull { it.getCharacteristic(uuid) }.firstOrNull()

    // ---- watchdog ------------------------------------------------------------------------
    private fun watchdog() {
        val now = System.currentTimeMillis()
        // A GATT op whose callback never arrives would stall the queue forever.
        if (opInFlight != null && now - opStartedAt > 8_000) { log("gatt", "op timeout $opInFlight"); completeOp() }
        drain.onTimeout(now)?.let(::perform)
        val s = _state.value
        if (s.status == LinkStatus.CONNECTED && s.heartRateAt > 0 && now - s.heartRateAt > 90_000 && s.onWrist && !drain.isActive) {
            // Connected but silent: re-arm notifications, then force a reconnect if still silent.
            log("watchdog", "hr silent; re-arming")
            enqueue(Op.Notify(WhoopUuids.heartRateMeasurement, true))
            if (now - s.heartRateAt > 240_000) { teardown(); setStatus(LinkStatus.DISCONNECTED); scheduleReconnect() }
        }
        liveBuffer.flushIfDue(now)
        motion.flushIfStale(now)?.let { m -> scope.launch { repo.insertMotion(listOf(m)) } }
        handler.postDelayed(::watchdog, 10_000)
    }

    private fun setStatus(s: LinkStatus) {
        if (_state.value.status == s) return
        _state.update { it.copy(status = s) }
        onConnectionChanged?.invoke(s)
    }

    private fun log(tag: String, msg: String) { scope.launch { repo.log(tag, msg) } }
}

/** API 35 exposes the type directly; earlier, infer it from the address (static random = top bits 11). */
@SuppressLint("NewApi")
internal fun addressTypeOf(d: BluetoothDevice): Int? = if (Build.VERSION.SDK_INT >= 35) d.addressType else null

internal fun inferAddressType(address: String): Int {
    val first = address.substring(0, 2).toIntOrNull(16) ?: return 1
    return if (first and 0xC0 == 0xC0 || first and 0xC0 == 0x40) 1 else 0
}

/** iOS AtriaHomeView.gapIsTerminallyStalled thresholds. */
const val TERMINAL_STALL_SLICES = 5
const val TERMINAL_STALL_WINDOW_MS = 4 * 60 * 60_000L

/** Batches live HR/RR writes (iOS checkpointing) so 1 Hz HR is not a write per sample. */
class LiveSampleBuffer(private val repo: Repository) {
    private val hr = ArrayList<Pair<Long, Int>>()
    private val rr = ArrayList<Pair<Long, Double>>()
    private var lastFlush = System.currentTimeMillis()

    @Synchronized
    fun add(t: Long, bpm: Int, rrMs: List<Double>) {
        hr += t to bpm
        // RR beats are stamped backwards from the notification time.
        var cursor = t
        for (ms in rrMs.reversed()) { rr += cursor to ms; cursor -= ms.toLong() }
    }

    fun flushIfDue(now: Long) { if (now - lastFlush >= 10_000) flush() }

    @Synchronized
    fun flush() {
        lastFlush = System.currentTimeMillis()
        if (hr.isEmpty() && rr.isEmpty()) return
        val h = hr.toList(); val r = rr.toList()
        hr.clear(); rr.clear()
        CoroutineScope(Dispatchers.IO).launch { repo.insertLive(h, r) }
    }
}
