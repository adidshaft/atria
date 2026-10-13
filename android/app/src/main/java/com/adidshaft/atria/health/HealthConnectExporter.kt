package com.adidshaft.atria.health

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.ExerciseRoute
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Energy
import androidx.health.connect.client.units.Length
import com.adidshaft.atria.analytics.SleepStage
import com.adidshaft.atria.data.Repository
import com.adidshaft.atria.domain.WorkoutRuntime
import com.adidshaft.atria.domain.decodeStages
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * HealthKitExporter → Health Connect. Same opt-in rule: nothing is written
 * until the user enables export and grants permission. Only confirmed sleep
 * and workouts are exported. Android gains native RMSSD (iOS had to export
 * SDNN because HealthKit has no RMSSD type).
 */
class HealthConnectExporter(private val context: Context, private val repo: Repository) {
    companion object {
        val PERMISSIONS = setOf(
            HealthPermission.getWritePermission(HeartRateRecord::class),
            HealthPermission.getWritePermission(RestingHeartRateRecord::class),
            HealthPermission.getWritePermission(HeartRateVariabilityRmssdRecord::class),
            HealthPermission.getWritePermission(RespiratoryRateRecord::class),
            HealthPermission.getWritePermission(ActiveCaloriesBurnedRecord::class),
            HealthPermission.getWritePermission(ExerciseSessionRecord::class),
            HealthPermission.getWritePermission(SleepSessionRecord::class),
            HealthPermission.getWritePermission(StepsRecord::class),
            HealthPermission.PERMISSION_WRITE_EXERCISE_ROUTE,
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(SleepSessionRecord::class),
        )
        /** Optional fitness context (iOS NutritionContext): body mass and dietary energy, read-only. */
        val CONTEXT_PERMISSIONS = setOf(
            HealthPermission.getReadPermission(androidx.health.connect.client.records.WeightRecord::class),
            HealthPermission.getReadPermission(androidx.health.connect.client.records.NutritionRecord::class),
        )

        fun availability(context: Context): Int = HealthConnectClient.getSdkStatus(context)
        fun isAvailable(context: Context) = availability(context) == HealthConnectClient.SDK_AVAILABLE
    }

    private val client by lazy { HealthConnectClient.getOrCreate(context) }
    private val device = Device(type = Device.TYPE_FITNESS_BAND, manufacturer = "WHOOP", model = "4.0")
    private fun meta(id: String) = Metadata.autoRecorded(device = device, clientRecordId = id)
    private fun offset(ms: Long): ZoneOffset = ZoneId.systemDefault().rules.getOffset(Instant.ofEpochMilli(ms))

    suspend fun hasPermissions(): Boolean = runCatching { client.permissionController.getGrantedPermissions().containsAll(PERMISSIONS) }.getOrDefault(false)

    /** Latest weight (kg) from Health Connect, if permitted. */
    suspend fun latestWeightKg(): Double? = runCatching {
        val r = client.readRecords(androidx.health.connect.client.request.ReadRecordsRequest(
            androidx.health.connect.client.records.WeightRecord::class,
            androidx.health.connect.client.time.TimeRangeFilter.after(Instant.now().minus(java.time.Duration.ofDays(90))),
        ))
        r.records.maxByOrNull { it.time }?.weight?.inKilograms
    }.getOrNull()

    /** Dietary energy logged today (kcal), if permitted. */
    suspend fun todayIntakeKcal(): Double? = runCatching {
        val start = java.time.LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant()
        val r = client.readRecords(androidx.health.connect.client.request.ReadRecordsRequest(
            androidx.health.connect.client.records.NutritionRecord::class,
            androidx.health.connect.client.time.TimeRangeFilter.after(start),
        ))
        r.records.mapNotNull { it.energy?.inKilocalories }.takeIf { it.isNotEmpty() }?.sum()
    }.getOrNull()

    suspend fun exportPending(): Int {
        if (!isAvailable(context) || !hasPermissions()) return 0
        var written = 0
        val records = ArrayList<Record>()

        for (s in repo.db.sleeps().unexported()) {
            val stages = decodeStages(s.stagesJson).map {
                SleepSessionRecord.Stage(Instant.ofEpochMilli(it.startMs), Instant.ofEpochMilli(it.endMs), when (it.stage) {
                    SleepStage.AWAKE -> SleepSessionRecord.STAGE_TYPE_AWAKE
                    SleepStage.REM -> SleepSessionRecord.STAGE_TYPE_REM
                    SleepStage.LIGHT -> SleepSessionRecord.STAGE_TYPE_LIGHT
                    SleepStage.DEEP -> SleepSessionRecord.STAGE_TYPE_DEEP
                })
            }
            records += SleepSessionRecord(
                startTime = Instant.ofEpochMilli(s.startMs), startZoneOffset = offset(s.startMs),
                endTime = Instant.ofEpochMilli(s.endMs), endZoneOffset = offset(s.endMs),
                metadata = meta("sleep-${s.id}"), title = if (s.isNap) "Nap" else "Sleep",
                stages = if (s.motionValidated) stages else emptyList(),
            )
            s.restingHr?.let { records += RestingHeartRateRecord(Instant.ofEpochMilli(s.endMs), offset(s.endMs), it.toLong(), meta("rhr-${s.id}")) }
            s.rmssd?.let { records += HeartRateVariabilityRmssdRecord(Instant.ofEpochMilli(s.endMs), offset(s.endMs), it.coerceIn(1.0, 200.0), meta("hrv-${s.id}")) }
            s.respiratoryRate?.let { records += RespiratoryRateRecord(Instant.ofEpochMilli(s.endMs), offset(s.endMs), it, meta("resp-${s.id}")) }
            repo.db.sleeps().upsert(s.copy(exportedToHealthConnect = true))
        }

        for (w in repo.db.workouts().unexported()) {
            val route = WorkoutRuntime.decodeRoute(w.routeJson)
            records += ExerciseSessionRecord(
                startTime = Instant.ofEpochMilli(w.startMs), startZoneOffset = offset(w.startMs),
                endTime = Instant.ofEpochMilli(w.endMs), endZoneOffset = offset(w.endMs),
                metadata = meta("workout-${w.id}"), exerciseType = ExerciseTypes.of(w.activity), title = w.activity,
                exerciseRoute = if (route.size >= 2) ExerciseRoute(route.map { ExerciseRoute.Location(Instant.ofEpochMilli(it.t), it.lat, it.lon, altitude = it.alt?.let(Length::meters)) }) else null,
            )
            val hr = repo.hr(w.startMs, w.endMs)
            if (hr.isNotEmpty()) records += HeartRateRecord(
                Instant.ofEpochMilli(w.startMs), offset(w.startMs), Instant.ofEpochMilli(w.endMs), offset(w.endMs),
                hr.filterIndexed { i, _ -> i % 5 == 0 }.map { HeartRateRecord.Sample(Instant.ofEpochMilli(it.t), it.bpm.toLong()) }, meta("hr-workout-${w.id}"),
            )
            w.calories?.takeIf { it > 0 }?.let { records += ActiveCaloriesBurnedRecord(Instant.ofEpochMilli(w.startMs), offset(w.startMs), Instant.ofEpochMilli(w.endMs), offset(w.endMs), Energy.kilocalories(it), meta("kcal-${w.id}")) }
            w.steps?.takeIf { it > 0 }?.let { records += StepsRecord(Instant.ofEpochMilli(w.startMs), offset(w.startMs), Instant.ofEpochMilli(w.endMs), offset(w.endMs), it.toLong(), meta("steps-${w.id}")) }
            repo.db.workouts().upsert(w.copy(exportedToHealthConnect = true))
        }

        records.chunked(500).forEach { chunk -> client.insertRecords(chunk); written += chunk.size }
        return written
    }
}

object ExerciseTypes {
    fun of(activity: String): Int = when (activity) {
        "Running", "Track & field" -> ExerciseSessionRecord.EXERCISE_TYPE_RUNNING
        "Walking", "Dog walking" -> ExerciseSessionRecord.EXERCISE_TYPE_WALKING
        "Hiking" -> ExerciseSessionRecord.EXERCISE_TYPE_HIKING
        "Cycling", "Spin", "Assault bike", "Mountain biking" -> ExerciseSessionRecord.EXERCISE_TYPE_BIKING
        "Strength", "Powerlifting", "Functional" -> ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING
        "HIIT" -> ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING
        "Yoga" -> ExerciseSessionRecord.EXERCISE_TYPE_YOGA
        "Pilates" -> ExerciseSessionRecord.EXERCISE_TYPE_PILATES
        "Swimming" -> ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL
        "Rowing" -> ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE
        "Elliptical" -> ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL
        "Stair climber" -> ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING_MACHINE
        "Dance" -> ExerciseSessionRecord.EXERCISE_TYPE_DANCING
        "Boxing", "Kickboxing" -> ExerciseSessionRecord.EXERCISE_TYPE_BOXING
        "Martial arts", "Jiu jitsu", "Wrestling" -> ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS
        "Basketball" -> ExerciseSessionRecord.EXERCISE_TYPE_BASKETBALL
        "Football / soccer" -> ExerciseSessionRecord.EXERCISE_TYPE_SOCCER
        "Cricket" -> ExerciseSessionRecord.EXERCISE_TYPE_CRICKET
        "Tennis" -> ExerciseSessionRecord.EXERCISE_TYPE_TENNIS
        "Badminton" -> ExerciseSessionRecord.EXERCISE_TYPE_BADMINTON
        "Volleyball" -> ExerciseSessionRecord.EXERCISE_TYPE_VOLLEYBALL
        "Golf" -> ExerciseSessionRecord.EXERCISE_TYPE_GOLF
        "Climbing" -> ExerciseSessionRecord.EXERCISE_TYPE_ROCK_CLIMBING
        "Skiing" -> ExerciseSessionRecord.EXERCISE_TYPE_SKIING
        "Snowboarding" -> ExerciseSessionRecord.EXERCISE_TYPE_SNOWBOARDING
        "Surfing" -> ExerciseSessionRecord.EXERCISE_TYPE_SURFING
        "Squash" -> ExerciseSessionRecord.EXERCISE_TYPE_SQUASH
        "Table tennis" -> ExerciseSessionRecord.EXERCISE_TYPE_TABLE_TENNIS
        "Rugby" -> ExerciseSessionRecord.EXERCISE_TYPE_RUGBY
        "Baseball" -> ExerciseSessionRecord.EXERCISE_TYPE_BASEBALL
        "Softball" -> ExerciseSessionRecord.EXERCISE_TYPE_SOFTBALL
        "Ice hockey" -> ExerciseSessionRecord.EXERCISE_TYPE_ICE_HOCKEY
        "Ice skating" -> ExerciseSessionRecord.EXERCISE_TYPE_ICE_SKATING
        "Handball" -> ExerciseSessionRecord.EXERCISE_TYPE_HANDBALL
        "Fencing" -> ExerciseSessionRecord.EXERCISE_TYPE_FENCING
        "Gymnastics" -> ExerciseSessionRecord.EXERCISE_TYPE_GYMNASTICS
        "Water polo" -> ExerciseSessionRecord.EXERCISE_TYPE_WATER_POLO
        "Sailing" -> ExerciseSessionRecord.EXERCISE_TYPE_SAILING
        "Paddleboarding" -> ExerciseSessionRecord.EXERCISE_TYPE_PADDLING
        "Kayaking" -> ExerciseSessionRecord.EXERCISE_TYPE_PADDLING
        "Skateboarding", "Inline skating" -> ExerciseSessionRecord.EXERCISE_TYPE_SKATING
        "Meditation", "Breathwork" -> ExerciseSessionRecord.EXERCISE_TYPE_GUIDED_BREATHING
        "Mobility", "Barre" -> ExerciseSessionRecord.EXERCISE_TYPE_STRETCHING
        "Jump rope" -> ExerciseSessionRecord.EXERCISE_TYPE_CALISTHENICS
        else -> ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT
    }
}
