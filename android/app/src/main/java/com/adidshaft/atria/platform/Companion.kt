package com.adidshaft.atria.platform

import android.app.Activity
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.companion.CompanionDeviceService
import android.content.Context
import android.content.IntentSender
import android.os.Build
import android.os.ParcelUuid
import androidx.annotation.RequiresApi
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.protocol.WhoopUuids
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * CompanionDeviceManager association: the closest Android analogue of
 * CoreBluetooth's background privileges. An associated app may start its
 * foreground service from the background, is exempt from some battery
 * restrictions, and (API 31+) is woken by [CompanionPresenceService] when the
 * strap comes into range — like an iOS state-restoration relaunch.
 */
object CompanionPairing {
    fun associate(activity: Activity, onChooser: (IntentSender) -> Unit, onError: (String) -> Unit) {
        val cdm = activity.getSystemService(CompanionDeviceManager::class.java) ?: return onError("Companion pairing unavailable")
        val filter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(ScanFilter.Builder().setServiceUuid(ParcelUuid(WhoopUuids.strapService)).build())
            .build()
        val request = AssociationRequest.Builder().addDeviceFilter(filter).setSingleDevice(false).build()
        val cb = object : CompanionDeviceManager.Callback() {
            @Deprecated("API < 33")
            override fun onDeviceFound(chooserLauncher: IntentSender) = onChooser(chooserLauncher)
            override fun onAssociationPending(intentSender: IntentSender) = onChooser(intentSender)
            override fun onFailure(error: CharSequence?) = onError(error?.toString() ?: "Association failed")
        }
        if (Build.VERSION.SDK_INT >= 33) cdm.associate(request, activity.mainExecutor, cb)
        else @Suppress("DEPRECATION") cdm.associate(request, cb, null)
    }

    /** After the user picks the strap, start presence observation (API 31+). */
    fun observe(context: Context, address: String) {
        if (Build.VERSION.SDK_INT < 31) return
        val cdm = context.getSystemService(CompanionDeviceManager::class.java) ?: return
        @Suppress("DEPRECATION")
        runCatching { cdm.startObservingDevicePresence(address) }
    }

    fun disassociateAll(context: Context) {
        val cdm = context.getSystemService(CompanionDeviceManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 33) cdm.myAssociations.forEach { runCatching { cdm.disassociate(it.id) } }
        else @Suppress("DEPRECATION") cdm.associations.forEach { runCatching { cdm.disassociate(it) } }
    }
}

@RequiresApi(31)
class CompanionPresenceService : CompanionDeviceService() {
    @Deprecated("API 31-32 signature")
    override fun onDeviceAppeared(address: String) = wake()

    @RequiresApi(33)
    override fun onDeviceAppeared(associationInfo: AssociationInfo) = wake()

    private fun wake() {
        CoroutineScope(Dispatchers.IO).launch {
            if (AtriaApp.graph.repo.settings.currentStrap().pairedAddress != null) StrapService.start(applicationContext)
        }
    }
}
