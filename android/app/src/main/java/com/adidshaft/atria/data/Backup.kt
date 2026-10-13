package com.adidshaft.atria.data

import android.content.Context
import android.net.Uri
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Local-only backup (AtriaZipWriter + AtriaRawExport + restore transaction).
 * The user picks the destination with the Storage Access Framework; nothing
 * is uploaded. Raw HR/RR are exported as CSV (docs/export-schema.md shape),
 * everything derived as JSON so a restore is lossless.
 */
class Backup(private val context: Context, private val repo: Repository) {
    @Serializable
    data class Manifest(val app: String = "atria-android", val schema: Int = 1, val createdAt: Long, val hrRows: Int, val sleeps: Int, val workouts: Int)

    suspend fun export(uri: Uri, from: Long = 0, to: Long = Long.MAX_VALUE) {
        val db = repo.db
        val sleeps = db.sleeps().between(from, to)
        val workouts = db.workouts().between(from, to)
        val journal = db.journal().all()
        val daily = db.daily().range(Long.MIN_VALUE / 2, Long.MAX_VALUE / 2)
        val hr = db.samples().hr(from, to)
        val rr = db.samples().rr(from, to)
        val motion = db.samples().motion(from, to)
        context.contentResolver.openOutputStream(uri)?.use { os ->
            ZipOutputStream(os).use { z ->
                fun put(name: String, text: String) { z.putNextEntry(ZipEntry(name)); z.write(text.toByteArray()); z.closeEntry() }
                put("manifest.json", AppJson.encodeToString(Manifest.serializer(), Manifest(createdAt = System.currentTimeMillis(), hrRows = hr.size, sleeps = sleeps.size, workouts = workouts.size)))
                put("sleeps.json", AppJson.encodeToString(ListSerializer(SleepEntity.serializer()), sleeps))
                put("workouts.json", AppJson.encodeToString(ListSerializer(WorkoutEntity.serializer()), workouts))
                put("journal.json", AppJson.encodeToString(ListSerializer(JournalEntity.serializer()), journal))
                put("daily.json", AppJson.encodeToString(ListSerializer(DailyMetricsEntity.serializer()), daily))
                put("settings.json", AppJson.encodeToString(AppSettings.serializer(), repo.settings.current()))
                z.putNextEntry(ZipEntry("heart_rate.csv"))
                z.write("unix_ms,bpm,source\n".toByteArray())
                hr.forEach { z.write("${it.t},${it.bpm},${it.source}\n".toByteArray()) }
                z.closeEntry()
                z.putNextEntry(ZipEntry("rr_intervals.csv"))
                z.write("unix_ms,rr_ms,source\n".toByteArray())
                rr.forEach { z.write("${it.t},${"%.1f".format(it.ms)},${it.source}\n".toByteArray()) }
                z.closeEntry()
                z.putNextEntry(ZipEntry("motion_minutes.csv"))
                z.write("minute_unix_ms,steps,activity_g,still_fraction,samples\n".toByteArray())
                motion.forEach { z.write("${it.startMs},${it.steps},${"%.4f".format(it.activityG)},${"%.3f".format(it.stillFraction)},${it.samples}\n".toByteArray()) }
                z.closeEntry()
            }
        }
    }

    /** Restore is additive (IGNORE on raw rows, upsert on derived) so it can never delete local data. */
    suspend fun restore(uri: Uri): Int {
        var restored = 0
        context.contentResolver.openInputStream(uri)?.use { input ->
            ZipInputStream(input).use { z ->
                while (true) {
                    val e = z.nextEntry ?: break
                    val bytes = z.readBytes()
                    val text = String(bytes)
                    when (e.name) {
                        "sleeps.json" -> AppJson.decodeFromString(ListSerializer(SleepEntity.serializer()), text).forEach { repo.db.sleeps().upsert(it); restored++ }
                        "workouts.json" -> AppJson.decodeFromString(ListSerializer(WorkoutEntity.serializer()), text).forEach { repo.db.workouts().upsert(it); restored++ }
                        "journal.json" -> AppJson.decodeFromString(ListSerializer(JournalEntity.serializer()), text).forEach { repo.db.journal().upsert(it); restored++ }
                        "daily.json" -> AppJson.decodeFromString(ListSerializer(DailyMetricsEntity.serializer()), text).forEach { repo.db.daily().upsert(it); restored++ }
                        "heart_rate.csv" -> text.lineSequence().drop(1).mapNotNull { l -> l.split(",").takeIf { it.size >= 3 }?.let { HrSampleEntity(it[0].toLong(), it[1].toInt(), it[2]) } }
                            .chunked(5_000).forEach { repo.db.samples().insertHr(it); restored += it.size }
                        "rr_intervals.csv" -> text.lineSequence().drop(1).mapNotNull { l -> l.split(",").takeIf { it.size >= 3 }?.let { RrEntity(it[0].toLong(), it[1].toDouble(), it[2]) } }
                            .chunked(5_000).forEach { repo.db.samples().insertRr(it); restored += it.size }
                        "motion_minutes.csv" -> text.lineSequence().drop(1).mapNotNull { l -> l.split(",").takeIf { it.size >= 5 }?.let { MotionMinuteEntity(it[0].toLong(), it[1].toInt(), it[2].toDouble(), it[3].toDouble(), it[4].toInt()) } }
                            .chunked(5_000).forEach { repo.db.samples().upsertMotion(it) }
                    }
                }
            }
        }
        return restored
    }
}
