package com.adidshaft.atria.ui.assistant

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.coach.Coach
import com.adidshaft.atria.ui.components.CircleButton
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import kotlinx.coroutines.launch

private data class Message(val fromUser: Boolean, val title: String, val body: String, val onDevice: Boolean = false)

@Composable
fun AssistantScreen(onBack: () -> Unit) {
    val s = LocalSurfaces.current
    val coach = AtriaApp.graph.coach
    val scope = rememberCoroutineScope()
    val messages = remember { mutableStateListOf<Message>() }
    var input by remember { mutableStateOf("") }
    var thinking by remember { mutableStateOf(false) }
    var state by remember { mutableStateOf(Coach.ModelState.UNAVAILABLE) }
    val list = rememberLazyListState()
    LaunchedEffect(Unit) { state = coach.modelState() }
    LaunchedEffect(messages.size) { if (messages.isNotEmpty()) list.animateScrollToItem(messages.size - 1) }

    fun ask(q: String) {
        if (q.isBlank() || thinking) return
        messages += Message(true, "", q)
        input = ""
        thinking = true
        scope.launch {
            val r = coach.ask(q)
            messages += Message(false, r.title, r.body, r.onDevice)
            thinking = false
        }
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            CircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", size = 46.dp, onClick = onBack)
            Spacer(Modifier.width(12.dp))
            Column {
                Text("Coach", style = MaterialTheme.typography.titleLarge)
                Text(
                    when (state) {
                        Coach.ModelState.AVAILABLE -> "Gemini Nano on this phone · your health data stays here"
                        Coach.ModelState.DOWNLOADABLE, Coach.ModelState.DOWNLOADING -> "On-device model can be downloaded · using built-in answers"
                        Coach.ModelState.UNAVAILABLE -> "Built-in answers from your data · nothing leaves your phone"
                    },
                    style = MaterialTheme.typography.bodySmall, color = s.textSecondary,
                )
            }
        }
        if (state == Coach.ModelState.DOWNLOADABLE) PillButton("Download on-device model", Modifier.padding(horizontal = 16.dp).fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 44.dp) {
            scope.launch { state = Coach.ModelState.DOWNLOADING; coach.download(); state = coach.modelState() }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (messages.isEmpty()) item {
                Text("Ask about your recovery, sleep, HRV, strain or stress.", color = s.textSecondary)
                Spacer(Modifier.padding(6.dp))
                listOf("How did I sleep?", "Should I push today?", "How is my HRV?", "Why is my stress high?").forEach { q ->
                    PillButton(q, Modifier.padding(vertical = 4.dp), color = s.card, contentColor = s.textPrimary, height = 44.dp) { ask(q) }
                }
            }
            items(messages) { m ->
                Box(Modifier.fillMaxWidth(), contentAlignment = if (m.fromUser) Alignment.CenterEnd else Alignment.CenterStart) {
                    Column(
                        Modifier.widthIn(max = 320.dp).clip(RoundedCornerShape(20.dp)).background(if (m.fromUser) AtriaColors.strain else s.card).padding(14.dp),
                    ) {
                        if (m.title.isNotBlank()) Text(m.title, style = MaterialTheme.typography.titleSmall)
                        Text(m.body, style = MaterialTheme.typography.bodyMedium, color = if (m.fromUser) androidx.compose.ui.graphics.Color.White else s.textSecondary)
                    }
                }
            }
            if (thinking) item { Text("Thinking…", color = s.textTertiary) }
        }
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(input, { input = it }, Modifier.weight(1f), placeholder = { Text("Ask your coach") }, shape = RoundedCornerShape(50), singleLine = true)
            Spacer(Modifier.width(8.dp))
            CircleButton(Icons.AutoMirrored.Filled.Send, "Send", size = 52.dp, tint = AtriaColors.strain) { ask(input) }
        }
        Text("Fitness estimates, not medical advice.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary, modifier = Modifier.padding(start = 16.dp, bottom = 8.dp))
    }
}
