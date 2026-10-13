package com.adidshaft.atria.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.adidshaft.atria.platform.WakeAlarm
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.AtriaTheme
import com.adidshaft.atria.ui.theme.LocalSurfaces
import java.time.LocalTime
import java.time.format.DateTimeFormatter

/** Full-screen alarm UI shown over the lock screen (AlarmKit's system alert equivalent). */
class AlarmActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            AtriaTheme("dark") {
                val s = LocalSurfaces.current
                Column(Modifier.fillMaxSize().background(s.background).padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Text(LocalTime.now().format(DateTimeFormatter.ofPattern("h:mm")), style = MaterialTheme.typography.displayLarge)
                    Text("Good morning", style = MaterialTheme.typography.headlineMedium, color = s.textSecondary)
                    Spacer(Modifier.height(48.dp))
                    PillButton("Stop", Modifier.fillMaxWidth(), color = AtriaColors.strain, height = 64.dp) { WakeAlarm.stopRinging(this@AlarmActivity); finish() }
                    Spacer(Modifier.height(12.dp))
                    PillButton("Snooze 9 min", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 64.dp) { WakeAlarm.snooze(this@AlarmActivity); finish() }
                }
            }
        }
    }
}
