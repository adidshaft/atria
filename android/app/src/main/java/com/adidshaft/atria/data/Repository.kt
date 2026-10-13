package com.adidshaft.atria.data

import android.content.Context
import com.adidshaft.atria.analytics.EvidenceMinute
import com.adidshaft.atria.analytics.HrSample
import com.adidshaft.atria.analytics.RrInterval
import com.adidshaft.atria.ble.HistoryMotion
import com.adidshaft.atria.protocol.HistoricalRecord
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import java.time.LocalDate
import java.time.ZoneId

class Repository(context: Context) {
    val db = AtriaDatabase.get(context)
    val settings = SettingsRepository(context)
    private val zone: ZoneId get() = ZoneId.systemDefault()

    /** Emits whenever drained history lands, so the engine recomputes affected days. */
    private val _historyEvents = MutableSharedFlow<Long>(extraBufferCapacity = 4)
    val historyEvents: SharedFlow<Long> = _historyEvents

    suspend fun insertLive(hr: List<Pair<Long, Int>>, rr: List<Pair<Long, Double>>) {
        if (hr.isNotEmpty()) db.samples().insertHr(hr.map { HrSampleEntity(it.first, it.second, Source.LIVE) })
        if (rr.isNotEmpty()) db.samples().insertRr(rr.map { RrEntity(it.first, it.second, Source.LIVE) })
    }

    /** Durable write of one drained history page (called before the strap ACK). */
    suspend fun insertHistory(records: List<HistoricalRecord>, clockOffsetSeconds: Long) {
        if (records.isEmpty()) return
        val ignoreBefore = settings.currentStrap().historyIgnoreBeforeMs ?: Long.MIN_VALUE
        val hr = ArrayList<HrSampleEntity>()
        val rr = ArrayList<RrEntity>()
        val gravity = ArrayList<Pair<Long, com.adidshaft.atria.protocol.Gravity>>()
        for (r in records) {
            val t = (r.timestampSeconds + clockOffsetSeconds) * 1000 + ((r.subsecond ?: 0) * 1000L / 32_768)
            if (t < ignoreBefore) continue
            r.heartRate?.let { hr += HrSampleEntity(t, it, Source.HISTORY) }
            var cursor = t
            for (ms in r.rrIntervalsMs.reversed()) { rr += RrEntity(cursor, ms.toDouble(), Source.HISTORY); cursor -= ms }
            gravity += t to r.gravity
        }
        db.samples().insertHr(hr)
        db.samples().insertRr(rr)
        if (gravity.isEmpty()) return
        // History motion never overwrites live minutes that carry strap steps.
        val minutes = HistoryMotion.minutes(gravity)
        val existing = db.samples().motion(minutes.minOf { it.startMs }, minutes.maxOf { it.startMs }).map { it.startMs }.toSet()
        db.samples().upsertMotion(minutes.filter { it.startMs !in existing })
    }

    suspend fun onHistoryIngested() { _historyEvents.tryEmit(System.currentTimeMillis()) }

    suspend fun insertMotion(minutes: List<MotionMinuteEntity>) {
        if (minutes.isEmpty()) return
        // Two packets can close the same minute: merge rather than overwrite.
        val prior = db.samples().motion(minutes.minOf { it.startMs }, minutes.maxOf { it.startMs }).associateBy { it.startMs }
        db.samples().upsertMotion(minutes.map { m ->
            val p = prior[m.startMs] ?: return@map m
            val n = p.samples + m.samples
            MotionMinuteEntity(m.startMs, p.steps + m.steps, (p.activityG * p.samples + m.activityG * m.samples) / n, (p.stillFraction * p.samples + m.stillFraction * m.samples) / n, n)
        })
    }

    suspend fun insertSkinTemp(t: Long, celsius: Double) = db.samples().insertSkin(listOf(SkinTempEntity(t / 60_000 * 60_000, celsius)))

    suspend fun log(tag: String, message: String) {
        db.log().insert(EventLogEntity(t = System.currentTimeMillis(), tag = tag, message = message))
    }

    // ---- queries -------------------------------------------------------------------------
    suspend fun hr(from: Long, to: Long): List<HrSample> = db.samples().hr(from, to).map { HrSample(it.t, it.bpm) }
    suspend fun rr(from: Long, to: Long): List<RrInterval> = db.samples().rr(from, to).map { RrInterval(it.t, it.ms) }

    suspend fun evidenceMinutes(from: Long, to: Long): List<EvidenceMinute> {
        val hr = db.samples().hrMinutes(from, to).associateBy { it.minute }
        val motion = db.samples().motion(from, to).associateBy { it.startMs }
        val keys = (hr.keys + motion.keys).sorted()
        return keys.map { k ->
            val h = hr[k]; val m = motion[k]
            EvidenceMinute(k, h?.meanHr, h?.n ?: 0, m?.activityG, m?.steps ?: 0)
        }
    }

    fun dayBounds(day: LocalDate): Pair<Long, Long> {
        val start = day.atStartOfDay(zone).toInstant().toEpochMilli()
        val end = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli() - 1
        return start to end
    }

    fun today(): LocalDate = LocalDate.now(zone)
}
