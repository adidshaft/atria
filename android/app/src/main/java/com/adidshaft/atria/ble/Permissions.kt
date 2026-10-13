package com.adidshaft.atria.ble

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * iOS asks for Bluetooth once (NSBluetoothAlwaysUsageDescription). Android splits it:
 * SCAN/CONNECT on 12+, fine location for BLE scanning on ≤ 11, POST_NOTIFICATIONS on 13+.
 */
object Permissions {
    fun bluetooth(): Array<String> = if (Build.VERSION.SDK_INT >= 31)
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    fun notifications(): Array<String> = if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.POST_NOTIFICATIONS) else emptyArray()

    fun location(): Array<String> = arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)

    fun activityRecognition(): Array<String> = arrayOf(Manifest.permission.ACTIVITY_RECOGNITION)

    fun granted(context: Context, perms: Array<String>) = perms.all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }

    fun hasBluetooth(context: Context) = granted(context, bluetooth())
    fun hasNotifications(context: Context) = granted(context, notifications())
    fun hasLocation(context: Context) = granted(context, arrayOf(Manifest.permission.ACCESS_FINE_LOCATION))
}
