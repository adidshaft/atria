package com.adidshaft.atria.coach

import android.content.Context
import com.adidshaft.atria.analytics.Recovery
import com.adidshaft.atria.analytics.formatHours
import com.adidshaft.atria.data.DailyMetricsEntity
import com.adidshaft.atria.data.Repository
import com.adidshaft.atria.domain.MetricsEngine
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import kotlinx.coroutines.withTimeoutOrNull
import java.time.LocalDate
import java.time.format.DateTimeFormatter

/**
 * Apple FoundationModels (on-device) → ML Kit GenAI Prompt API (Gemini Nano
 * via AICore, on-device). Same contract as iOS: DATA-only prompt, ≤ 3
 * sentences, every figure must appear in DATA (audited), nothing leaves the
 * phone. Devices without Gemini Nano fall back to a deterministic,
 * template-based coach so the feature never disappears.
 */
class Coach(private val context: Context, private val repo: Repository, private val engine: MetricsEngine) {
    data class Reply(val title: String, val body: String, val onDevice: Boolean)

    enum class ModelState { AVAILABLE, DOWNLOADABLE, DOWNLOADING, UNAVAILABLE }

    private val model by lazy { runCatching { Generation.getClient() }.getOrNull() }

    /** ML Kit is never initialised unless the user opted in, so its telemetry never starts by default. */
    suspend fun modelState(): ModelState = if (repo.settings.current().coachMode != "on_device") ModelState.UNAVAILABLE else runCatching {
        when (model?.checkStatus()) {
            FeatureStatus.AVAILABLE -> ModelState.AVAILABLE
            FeatureStatus.DOWNLOADABLE -> ModelState.DOWNLOADABLE
            FeatureStatus.DOWNLOADING -> ModelState.DOWNLOADING
            else -> ModelState.UNAVAILABLE
        }
    }.getOrDefault(ModelState.UNAVAILABLE)

    suspend fun download() = runCatching { if (repo.settings.current().coachMode == "on_device") model?.download()?.collect { } }

    suspend fun dataBlock(): Pair<String, List<DailyMetricsEntity>> {
        val today = repo.today()
        val days = repo.db.daily().range(today.minusDays(6).toEpochDay(), today.toEpochDay())
        val fmt = DateTimeFormatter.ofPattern("EEE MMM d")
        val lines = mutableListOf("DATA")
        for (d in days) {
            val date = LocalDate.ofEpochDay(d.epochDay)
            val parts = buildList {
                d.recovery?.let { add("recovery $it%") }
                d.sleepHours?.let { add("sleep ${formatHours(it)}") }
                d.sleepPerformance?.let { add("sleep performance $it%") }
                d.hrv?.let { add("HRV ${it.toInt()} ms") }
                d.restingHr?.let { add("resting HR $it bpm") }
                d.strain?.let { add("strain %.1f".format(it)) }
                d.steps?.takeIf { it > 0 }?.let { add("steps $it") }
                d.respiratoryRate?.let { add("breathing %.1f per min".format(it)) }
            }
            lines += "${if (date == today) "Today (${date.format(fmt)})" else date.format(fmt)}: ${parts.joinToString(", ").ifEmpty { "no data" }}"
        }
        com.adidshaft.atria.health.HealthConnectExporter.takeIf { it.isAvailable(context) }?.let {
            com.adidshaft.atria.health.HealthConnectExporter(context, repo).todayIntakeKcal()?.let { kcal -> lines += "Food logged today: ${kcal.toInt()} kcal" }
        }
        val load = engine.trainingLoad()
        if (load.readiness != "learning") lines += "Training load: ${load.readiness}"
        return lines.joinToString("\n") to days
    }

    suspend fun ask(question: String): Reply {
        val (data, days) = dataBlock()
        if (repo.settings.current().coachMode == "on_device" && modelState() == ModelState.AVAILABLE) {
            val prompt = "$data\n\nYou are Atria's coach. Use plain, friendly words. Keep it short: at most three sentences. " +
                "Only use numbers that appear in DATA, written the same way, as digits. Never diagnose, never give medical advice, never mention being an AI.\n\nQuestion: $question"
            val text = withTimeoutOrNull(20_000) { runCatching { model?.generateContent(prompt)?.candidates?.firstOrNull()?.text }.getOrNull() }
            if (text != null && passesAudit(text, data)) {
                val lines = text.lines().map { it.trim().trim('#', '*', ' ') }.filter { it.isNotEmpty() }
                return if (lines.size > 1) Reply(lines.first(), lines.drop(1).joinToString(" "), true) else Reply("", lines.firstOrNull() ?: "", true)
            }
        }
        return templateReply(question, days)
    }

    /** Every multi-digit figure in the reply must appear in DATA; spelled-out numbers are rejected. */
    fun passesAudit(reply: String, data: String): Boolean {
        val figures = Regex("\\d+(?:\\.\\d+)?").findAll(reply).map { it.value }.filter { it.length >= 2 || it.contains('.') }
        val spelled = Regex("\\b(two|three|four|five|six|seven|eight|nine|ten|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)\\b", RegexOption.IGNORE_CASE)
        return figures.all { data.contains(it) } && !spelled.containsMatchIn(reply)
    }

    /** Deterministic coach used when no on-device model is present. */
    fun templateReply(question: String, days: List<DailyMetricsEntity>): Reply {
        val today = days.lastOrNull()
        val q = question.lowercase()
        val prior = days.dropLast(1)
        fun avg(sel: (DailyMetricsEntity) -> Double?) = prior.mapNotNull(sel).takeIf { it.isNotEmpty() }?.average()
        return when {
            "sleep" in q || "tired" in q -> {
                val s = today?.sleepHours
                val need = today?.sleepNeedHours
                if (s == null) Reply("No sleep yet", "Wear the strap tonight and Atria will measure your sleep and set tomorrow's need.", false)
                else Reply("You slept ${formatHours(s)}", buildString {
                    need?.let { append("Tonight's need is ${formatHours(it)}. ") }
                    avg { it.sleepHours }?.let { a -> append(if (s >= a) "That's at or above your recent average." else "That's below your recent average of ${formatHours(a)}.") }
                }.trim(), false)
            }
            "hrv" in q -> {
                val h = today?.hrv
                if (h == null) Reply("HRV is calibrating", "HRV comes from a steady overnight window. A few more nights will set your baseline.", false)
                else Reply("HRV ${h.toInt()} ms", avg { it.hrv }?.let { a -> if (h >= a) "Above your recent ${a.toInt()} ms average, a sign of good recovery." else "Below your recent ${a.toInt()} ms average. Keep today lighter if you feel it." } ?: "Keep wearing the strap overnight to build your baseline.", false)
            }
            "strain" in q || "train" in q || "workout" in q || "push" in q -> {
                val r = today?.recovery
                val st = today?.strain ?: 0.0
                Reply(if ((r ?: 50) >= 67) "Room to push" else if ((r ?: 50) >= 34) "Build gently" else "Take it easy",
                    "Strain so far is %.1f. ".format(st) + when {
                        r == null -> "Recovery is still calculating, so keep effort moderate."
                        r >= 67 -> "With $r% recovery a harder session is reasonable."
                        r >= 34 -> "At $r% recovery, a moderate session fits best."
                        else -> "At $r% recovery, favor rest, mobility or an easy walk."
                    }, false)
            }
            "stress" in q -> Reply("Stress", today?.stressAverage?.let { "Today's average stress is %.1f on a 0 to 3 scale. Slow breathing for a few minutes can bring it down.".format(it) } ?: "Stress needs a few minutes of steady heart rate to calculate.", false)
            "step" in q || "walk" in q -> Reply("${today?.steps ?: 0} steps", "Steps are counted from the strap's own motion sensor.", false)
            else -> {
                val r = today?.recovery
                Reply(r?.let { "Recovery $it%" } ?: "Getting to know you",
                    r?.let { "${Recovery.band(it)} recovery today. Ask about sleep, HRV, strain or stress for detail." } ?: "Wear the strap overnight and Atria will learn your baseline.", false)
            }
        }
    }
}
