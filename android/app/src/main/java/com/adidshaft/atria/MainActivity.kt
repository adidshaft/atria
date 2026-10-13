package com.adidshaft.atria

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import com.adidshaft.atria.ble.Permissions
import com.adidshaft.atria.platform.StrapService
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.AtriaRoot
import com.adidshaft.atria.ui.onboarding.OnboardingFlow
import com.adidshaft.atria.ui.theme.AtriaTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()
    /** Deep link (atria://…) waiting to be consumed by the nav host. */
    val pendingLink = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        handleIntent(intent)
        setContent {
            val settings by vm.settings.collectAsStateWithLifecycle()
            AtriaTheme(settings.theme) {
                if (!settings.onboardingComplete) OnboardingFlow(vm) else AtriaRoot(vm, pendingLink)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // Re-establish the standing connection whenever the UI comes back (iOS foreground authority).
        lifecycleScope.launch {
            val strapState = AtriaApp.graph.repo.settings.currentStrap()
            val paired = strapState.pairedAddress != null && !strapState.capturePaused
            // Android 12+ only allows FGS starts from a visible activity (or CDM/boot exemptions),
            // so the foreground UI is the authoritative place to (re)start the service.
            if ((paired && Permissions.hasBluetooth(this@MainActivity)) || AtriaApp.graph.workouts.live.value != null) StrapService.start(this@MainActivity)
            AtriaApp.graph.broadcaster.setEnabled(AtriaApp.graph.repo.settings.current().heartRateBroadcast)
        }
        vm.refreshNow()
    }

    private fun handleIntent(intent: Intent?) {
        intent?.data?.takeIf { it.scheme == "atria" }?.let { uri ->
            val token = (uri.host ?: uri.pathSegments.firstOrNull() ?: "today").lowercase()
            // atria://compare?d=… carries a Face-Off payload; keep it intact for the nav host.
            pendingLink.value = if (token == "compare") "compare:" + (uri.getQueryParameter("d") ?: "") else token
        }
        if (intent?.action == "androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" || intent?.action == Intent.ACTION_VIEW_PERMISSION_USAGE) {
            pendingLink.value = "privacy"
        }
    }
}
