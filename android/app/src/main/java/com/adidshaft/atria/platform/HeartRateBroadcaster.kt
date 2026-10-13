package com.adidshaft.atria.platform

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import com.adidshaft.atria.ble.Permissions
import com.adidshaft.atria.protocol.WhoopUuids
import java.util.concurrent.CopyOnWriteArraySet
import kotlin.math.roundToInt

/**
 * CBPeripheralManager → BluetoothGattServer + BluetoothLeAdvertiser.
 * Re-broadcasts the strap HR as a standard Heart Rate Service so gym
 * equipment, bike computers and other apps can read it ("Atria_HR").
 */
@SuppressLint("MissingPermission")
class HeartRateBroadcaster(private val context: Context) {
    private val manager = context.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null
    private var hrChar: BluetoothGattCharacteristic? = null
    private val subscribers = CopyOnWriteArraySet<BluetoothDevice>()
    var enabled = false
        private set
    var status = "off"
        private set

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) { status = "advertising" }
        override fun onStartFailure(errorCode: Int) { status = "advertise_failed_$errorCode" }
    }

    fun setEnabled(on: Boolean) {
        if (on == enabled) return
        enabled = on
        if (on) start() else stop()
    }

    private fun start() {
        if (!Permissions.hasBluetooth(context) || (Build.VERSION.SDK_INT >= 31 && !Permissions.granted(context, arrayOf(android.Manifest.permission.BLUETOOTH_ADVERTISE)))) {
            status = "permission_missing"; return
        }
        val adapter = manager?.adapter ?: return
        val s = manager.openGattServer(context, callback) ?: return
        val service = BluetoothGattService(WhoopUuids.heartRateService, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val c = BluetoothGattCharacteristic(WhoopUuids.heartRateMeasurement, BluetoothGattCharacteristic.PROPERTY_NOTIFY, 0)
        c.addDescriptor(BluetoothGattDescriptor(WhoopUuids.clientCharacteristicConfig, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
        service.addCharacteristic(c)
        s.addService(service)
        server = s; hrChar = c
        val advertiser = adapter.bluetoothLeAdvertiser ?: run { status = "advertising_unsupported"; return }
        advertiser.startAdvertising(
            AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED).setConnectable(true).setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM).build(),
            AdvertiseData.Builder().setIncludeDeviceName(false).addServiceUuid(ParcelUuid(WhoopUuids.heartRateService)).build(),
            AdvertiseData.Builder().setIncludeDeviceName(true).build(),
            advertiseCallback,
        )
    }

    private fun stop() {
        runCatching { manager?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        runCatching { server?.close() }
        server = null; hrChar = null; subscribers.clear(); status = "off"
    }

    fun publish(bpm: Int, rrMs: List<Double>) {
        val s = server ?: return
        val c = hrChar ?: return
        if (bpm <= 0 || subscribers.isEmpty()) return
        val bytes = ArrayList<Byte>()
        val hasRr = rrMs.isNotEmpty()
        bytes += (if (hasRr) 0x10 else 0x00).toByte()
        bytes += bpm.coerceIn(0, 255).toByte()
        rrMs.take(4).forEach { ms -> val v = (ms * 1024 / 1000).roundToInt(); bytes += (v and 0xFF).toByte(); bytes += ((v shr 8) and 0xFF).toByte() }
        val value = bytes.toByteArray()
        for (d in subscribers) {
            runCatching {
                if (Build.VERSION.SDK_INT >= 33) s.notifyCharacteristicChanged(d, c, false, value)
                else { @Suppress("DEPRECATION") c.value = value; @Suppress("DEPRECATION") s.notifyCharacteristicChanged(d, c, false) }
            }
        }
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState != android.bluetooth.BluetoothProfile.STATE_CONNECTED) subscribers.remove(device)
        }

        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) {
            if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) subscribers += device else subscribers -= device
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor) {
            val v = if (device in subscribers) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, v)
        }
    }
}
