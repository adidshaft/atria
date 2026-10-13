package com.adidshaft.atria.data

import android.content.Context
import com.adidshaft.atria.AtriaApp
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.GZIPOutputStream

/**
 * AtriaResearchBundle: anonymous research sharing, consent-first and
 * queue-only. Bundles use relative times (day index from the first record),
 * banded demographics and a revocable random pseudonym. Exactly like iOS,
 * there is no network transport: bundles queue in a 7-day local outbox and
 * leave the phone only when the user shares one explicitly.
 */
object ResearchBundle {
    @Serializable data class Day(val d: Int, val recovery: Int?, val strain: Double?, val sleepH: Double?, val rhr: Int?, val hrv: Double?, val resp: Double?, val steps: Int?)
    @Serializable data class Sleep(val d: Int, val startH: Double, val durH: Double, val nap: Boolean, val stagesMin: Map<String, Int>, val motionValidated: Boolean)
    @Serializable data class Workout(val d: Int, val activity: String, val durMin: Int, val strain: Double, val avgHr: Int)
    @Serializable data class Journal(val d: Int, val key: String, val value: String)
    @Serializable data class Payload(
        val schema: Int = 1, val platform: String = "android", val pseudonym: String, val ageBand: String, val sex: String,
        val days: List<Day>, val sleeps: List<Sleep>, val workouts: List<Workout>, val journal: List<Journal>,
    )

    private fun prefs(c: Context) = c.getSharedPreferences("research", Context.MODE_PRIVATE)
    fun consented(c: Context) = prefs(c).getString("pseudonym", null) != null
    fun grantConsent(c: Context) = prefs(c).edit().putString("pseudonym", UUID.randomUUID().toString()).apply()
    /** Revocation destroys the pseudonym so nothing later can be linked to earlier bundles. */
    fun revokeConsent(c: Context) { prefs(c).edit().remove("pseudonym").apply(); outbox(c).deleteRecursively() }

    fun ageBand(age: Int) = "${age / 10 * 10}-${age / 10 * 10 + 9}"

    suspend fun build(c: Context): Payload? {
        val pseudonym = prefs(c).getString("pseudonym", null) ?: return null
        val repo = AtriaApp.graph.repo
        val profile = repo.settings.current().profile
        val daily = repo.db.daily().range(0, Long.MAX_VALUE / 2).filter { it.recoveryConfidence != "sample data" }
        val first = daily.minOfOrNull { it.epochDay } ?: return null
        val zone = java.time.ZoneId.systemDefault()
        fun dayIdx(ms: Long) = (java.time.Instant.ofEpochMilli(ms).atZone(zone).toLocalDate().toEpochDay() - first).toInt()
        val sleeps = repo.db.sleeps().between(0, Long.MAX_VALUE).filter { it.status == "confirmed" && it.source != Source.DEMO }
        return Payload(
            pseudonym = pseudonym, ageBand = ageBand(profile.age), sex = profile.sex.lowercase(),
            days = daily.map { Day((it.epochDay - first).toInt(), it.recovery, it.strain, it.sleepHours, it.restingHr, it.hrv, it.respiratoryRate, it.steps) },
            sleeps = sleeps.map { s ->
                val local = java.time.Instant.ofEpochMilli(s.startMs).atZone(zone)
                Sleep(dayIdx(s.endMs), local.hour + local.minute / 60.0, s.asleepMs / 3_600_000.0, s.isNap,
                    com.adidshaft.atria.analytics.SleepDetector.stageMinutes(com.adidshaft.atria.domain.decodeStages(s.stagesJson)).mapKeys { it.key.name.lowercase() }, s.motionValidated)
            },
            workouts = repo.db.workouts().between(0, Long.MAX_VALUE).filter { it.status == "confirmed" && it.source != Source.DEMO }
                .map { Workout(dayIdx(it.startMs), it.activity, ((it.endMs - it.startMs) / 60_000).toInt(), it.strain, it.avgHr) },
            // Private categories (intimacy, wake reasons, cycle) are never included.
            journal = repo.db.journal().all().filter { it.key.startsWith("tag.") && !it.key.contains("sexual") && !it.key.contains("selfPleasure") }
                .map { Journal((it.epochDay - first).toInt(), it.key, it.value) },
        )
    }

    fun outbox(c: Context) = File(c.filesDir, "research-outbox")

    /** Gzipped JSON written to the outbox (or a share file). Returns the file and its SHA-256. */
    suspend fun writeBundle(c: Context, dir: File = outbox(c)): Pair<File, String>? {
        val p = build(c) ?: return null
        val bytes = AppJson.encodeToString(Payload.serializer(), p).toByteArray()
        dir.mkdirs()
        val f = File(dir, "atria-research-${java.time.LocalDate.now()}.json.gz")
        GZIPOutputStream(f.outputStream()).use { it.write(bytes) }
        val digest = MessageDigest.getInstance("SHA-256").digest(f.readBytes()).joinToString("") { "%02x".format(it) }
        return f to digest
    }

    /** Nightly queue (ProcessingWorker): keep a week of bundles, never transmit. */
    suspend fun nightlyQueue(c: Context) {
        if (!consented(c)) return
        writeBundle(c)
        outbox(c).listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 7L * 86_400_000 }?.forEach { it.delete() }
    }
}

/** AtriaSensorReferenceCapture: externally observed instrument readings for validation research. */
object SensorReference {
    @Serializable data class Entry(val t: Long, val kind: String, val value: Double?, val unit: String?, val device: String, val site: String?, val note: String?)

    private fun file(c: Context) = File(c.filesDir, "sensor-reference.json")
    fun load(c: Context): List<Entry> = runCatching { AppJson.decodeFromString(ListSerializer(Entry.serializer()), file(c).readText()) }.getOrDefault(emptyList())

    /** Validates like iOS: SpO₂ 70–100 %, skin 20–45 °C, device required. Returns an error message or null. */
    fun capture(c: Context, kind: String, value: Double?, unit: String?, device: String, site: String?, note: String?): String? {
        if (device.isBlank() && kind != "clock_marker") return "Reference device is required"
        when (kind) {
            "oxygen_reference" -> if (value == null || value !in 70.0..100.0) return "Oxygen must be 70–100 %"
            "skin_temperature_reference" -> {
                val cVal = if (unit == "degF") value?.let { (it - 32) * 5 / 9 } else value
                if (cVal == null || cVal !in 20.0..45.0) return "Temperature out of range"
                if (site.isNullOrBlank()) return "Measurement site is required"
            }
        }
        val all = (load(c) + Entry(System.currentTimeMillis(), kind, value, unit, device.trim().take(60), site?.trim()?.take(60), note?.trim()?.take(200))).takeLast(2_000)
        file(c).writeText(AppJson.encodeToString(ListSerializer(Entry.serializer()), all))
        return null
    }

    fun clear(c: Context) { file(c).delete() }

    fun csv(entries: List<Entry>): String = buildString {
        appendLine("unix_ms,kind,value,unit,device,site,note")
        entries.forEach { e -> appendLine(listOf(e.t, e.kind, e.value ?: "", e.unit ?: "", e.device, e.site ?: "", e.note ?: "").joinToString(",") { "\"" + it.toString().replace("\"", "\"\"") + "\"" }) }
    }
}

/** AtriaStepCalibrationPlan: manifest for tools/fit_step_calibration (walk/rest windows with counted steps). */
object StepCalibration {
    @Serializable data class Window(val label: String, val kind: String, val start_ms: Long, val end_ms: Long, val expected_steps: Int?, val strap_steps: Int?)
    @Serializable data class Manifest(val schema: Int = 1, val platform: String = "android", val cadence_spm: Int, val windows: List<Window>)
}
