package com.adidshaft.atria.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/** Source tags keep live and drained-history evidence distinguishable (provenance). */
object Source {
    const val LIVE = "live_2a37"
    const val HISTORY = "history_v24"
    const val R10 = "r10_realtime"
    const val MANUAL = "manual"
    const val DETECTED = "detected"
    const val DEMO = "demo"
    /** Unattributed strap-motion run awaiting the wearer's verdict. */
    const val MOTION = "motion"
}

@Entity(tableName = "hr_samples")
data class HrSampleEntity(@PrimaryKey val t: Long, val bpm: Int, val source: String)

@Entity(tableName = "rr_intervals")
data class RrEntity(@PrimaryKey val t: Long, val ms: Double, val source: String)

@Entity(tableName = "motion_minutes")
data class MotionMinuteEntity(
    @PrimaryKey val startMs: Long,
    val steps: Int,
    val activityG: Double,
    val stillFraction: Double,
    val samples: Int,
)

@Entity(tableName = "skin_temp")
data class SkinTempEntity(@PrimaryKey val t: Long, val celsius: Double)

@kotlinx.serialization.Serializable
@Entity(tableName = "sleeps", indices = [Index("startMs")])
data class SleepEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val startMs: Long,
    val endMs: Long,
    val asleepMs: Long,
    val isNap: Boolean,
    /** candidate | confirmed | dismissed */
    val status: String,
    /** detected | manual | demo */
    val source: String,
    val restingHr: Int? = null,
    val rmssd: Double? = null,
    val respiratoryRate: Double? = null,
    val efficiency: Double? = null,
    val stagesJson: String? = null,
    val motionValidated: Boolean = false,
    val disturbances: Int = 0,
    val needHours: Double? = null,
    val exportedToHealthConnect: Boolean = false,
)

@kotlinx.serialization.Serializable
@Entity(tableName = "workouts", indices = [Index("startMs")])
data class WorkoutEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val activity: String,
    val startMs: Long,
    val endMs: Long,
    val strain: Double,
    val avgHr: Int,
    val maxHr: Int,
    val calories: Double?,
    val steps: Int?,
    val zonesJson: String?,
    val routeJson: String? = null,
    val distanceMeters: Double? = null,
    val elevationGainMeters: Double? = null,
    /** active | confirmed | review | dismissed */
    val status: String,
    val source: String,
    val setsJson: String? = null,
    val notes: String? = null,
    val exportedToHealthConnect: Boolean = false,
)

@kotlinx.serialization.Serializable
@Entity(tableName = "journal", primaryKeys = ["epochDay", "key"])
data class JournalEntity(val epochDay: Long, val key: String, val value: String, val loggedAt: Long)

@kotlinx.serialization.Serializable
@Entity(tableName = "daily_metrics")
data class DailyMetricsEntity(
    @PrimaryKey val epochDay: Long,
    val recovery: Int? = null,
    val recoveryConfidence: String? = null,
    val strain: Double? = null,
    val sleepHours: Double? = null,
    val sleepNeedHours: Double? = null,
    val sleepPerformance: Int? = null,
    val restingHr: Int? = null,
    val hrv: Double? = null,
    val respiratoryRate: Double? = null,
    val steps: Int? = null,
    val activeCalories: Double? = null,
    val skinTempDelta: Double? = null,
    val stressAverage: Double? = null,
    val updatedAt: Long = 0,
)

@Entity(tableName = "stress_facts")
data class StressFactEntity(@PrimaryKey val t: Long, val score: Double, val confidence: String, val meanHr: Double)

@Entity(tableName = "event_log", indices = [Index("t")])
data class EventLogEntity(@PrimaryKey(autoGenerate = true) val id: Long = 0, val t: Long, val tag: String, val message: String)

@Dao
interface SampleDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun insertHr(samples: List<HrSampleEntity>)
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun insertRr(samples: List<RrEntity>)
    @Upsert suspend fun upsertMotion(m: List<MotionMinuteEntity>)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insertSkin(s: List<SkinTempEntity>)

    @Query("SELECT * FROM hr_samples WHERE t BETWEEN :from AND :to ORDER BY t") suspend fun hr(from: Long, to: Long): List<HrSampleEntity>
    @Query("SELECT * FROM rr_intervals WHERE t BETWEEN :from AND :to ORDER BY t") suspend fun rr(from: Long, to: Long): List<RrEntity>
    @Query("SELECT * FROM motion_minutes WHERE startMs BETWEEN :from AND :to ORDER BY startMs") suspend fun motion(from: Long, to: Long): List<MotionMinuteEntity>
    @Query("SELECT * FROM skin_temp WHERE t BETWEEN :from AND :to ORDER BY t") suspend fun skin(from: Long, to: Long): List<SkinTempEntity>
    @Query("SELECT COALESCE(SUM(steps),0) FROM motion_minutes WHERE startMs BETWEEN :from AND :to") suspend fun steps(from: Long, to: Long): Int
    @Query("SELECT * FROM hr_samples ORDER BY t DESC LIMIT 1") suspend fun latestHr(): HrSampleEntity?
    @Query("SELECT COUNT(*) FROM hr_samples WHERE source = :source") suspend fun countBySource(source: String): Int
    @Query("SELECT COUNT(*) FROM hr_samples") suspend fun hrCount(): Int
    @Query("SELECT MIN(t) FROM hr_samples") suspend fun firstHrTime(): Long?

    /** Minute aggregation done in SQL so a full day never materialises 86k rows in memory. */
    @Query("SELECT (t / 60000) * 60000 AS minute, AVG(bpm) AS meanHr, COUNT(*) AS n FROM hr_samples WHERE t BETWEEN :from AND :to GROUP BY t / 60000 ORDER BY minute")
    suspend fun hrMinutes(from: Long, to: Long): List<HrMinuteRow>

    @Query("DELETE FROM hr_samples WHERE t < :before") suspend fun pruneHr(before: Long)
    @Query("DELETE FROM rr_intervals WHERE t < :before") suspend fun pruneRr(before: Long)
    @Query("DELETE FROM hr_samples WHERE source = :source") suspend fun deleteHrBySource(source: String)
}

data class HrMinuteRow(val minute: Long, val meanHr: Double, val n: Int)

@Dao
interface SleepDao {
    @Insert suspend fun insert(s: SleepEntity): Long
    @Upsert suspend fun upsert(s: SleepEntity)
    @Query("SELECT * FROM sleeps WHERE endMs >= :from AND startMs <= :to ORDER BY startMs") suspend fun between(from: Long, to: Long): List<SleepEntity>
    @Query("SELECT * FROM sleeps WHERE status = 'confirmed' ORDER BY startMs DESC LIMIT :limit") suspend fun recentConfirmed(limit: Int): List<SleepEntity>
    @Query("SELECT * FROM sleeps WHERE status = 'candidate' ORDER BY startMs DESC") fun candidates(): Flow<List<SleepEntity>>
    @Query("SELECT * FROM sleeps WHERE status != 'dismissed' ORDER BY startMs DESC LIMIT 60") fun observeRecent(): Flow<List<SleepEntity>>
    @Query("SELECT * FROM sleeps WHERE id = :id") suspend fun get(id: Long): SleepEntity?
    @Query("UPDATE sleeps SET status = :status WHERE id = :id") suspend fun setStatus(id: Long, status: String)
    @Query("DELETE FROM sleeps WHERE id = :id") suspend fun delete(id: Long)
    @Query("SELECT * FROM sleeps WHERE status = 'confirmed' AND exportedToHealthConnect = 0") suspend fun unexported(): List<SleepEntity>
}

@Dao
interface WorkoutDao {
    @Insert suspend fun insert(w: WorkoutEntity): Long
    @Upsert suspend fun upsert(w: WorkoutEntity)
    @Query("SELECT * FROM workouts WHERE endMs >= :from AND startMs <= :to AND status != 'dismissed' ORDER BY startMs") suspend fun between(from: Long, to: Long): List<WorkoutEntity>
    @Query("SELECT * FROM workouts WHERE status != 'dismissed' ORDER BY startMs DESC LIMIT 100") fun observeRecent(): Flow<List<WorkoutEntity>>
    @Query("SELECT * FROM workouts WHERE status = 'review' ORDER BY startMs DESC") fun reviews(): Flow<List<WorkoutEntity>>
    @Query("SELECT * FROM workouts WHERE id = :id") suspend fun get(id: Long): WorkoutEntity?
    @Query("SELECT * FROM workouts WHERE status = 'active' LIMIT 1") suspend fun active(): WorkoutEntity?
    @Query("UPDATE workouts SET status = :status WHERE id = :id") suspend fun setStatus(id: Long, status: String)
    @Query("DELETE FROM workouts WHERE id = :id") suspend fun delete(id: Long)
    @Query("SELECT * FROM workouts WHERE status = 'confirmed' AND exportedToHealthConnect = 0") suspend fun unexported(): List<WorkoutEntity>
}

@Dao
interface JournalDao {
    @Upsert suspend fun upsert(e: JournalEntity)
    @Query("DELETE FROM journal WHERE epochDay = :day AND `key` = :key") suspend fun delete(day: Long, key: String)
    @Query("SELECT * FROM journal WHERE epochDay = :day") fun observeDay(day: Long): Flow<List<JournalEntity>>
    @Query("SELECT * FROM journal WHERE epochDay = :day") suspend fun day(day: Long): List<JournalEntity>
    @Query("SELECT * FROM journal ORDER BY epochDay") suspend fun all(): List<JournalEntity>
}

@Dao
interface DailyDao {
    @Upsert suspend fun upsert(d: DailyMetricsEntity)
    @Query("SELECT * FROM daily_metrics WHERE epochDay = :day") suspend fun get(day: Long): DailyMetricsEntity?
    @Query("SELECT * FROM daily_metrics WHERE epochDay = :day") fun observe(day: Long): Flow<DailyMetricsEntity?>
    @Query("SELECT * FROM daily_metrics WHERE epochDay BETWEEN :from AND :to ORDER BY epochDay") suspend fun range(from: Long, to: Long): List<DailyMetricsEntity>
    @Query("DELETE FROM daily_metrics WHERE recoveryConfidence = 'sample data'") suspend fun deleteSampleRows()
    @Query("SELECT * FROM daily_metrics WHERE epochDay BETWEEN :from AND :to ORDER BY epochDay") fun observeRange(from: Long, to: Long): Flow<List<DailyMetricsEntity>>
}

@Dao
interface StressDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insert(f: StressFactEntity)
    @Query("SELECT * FROM stress_facts WHERE t BETWEEN :from AND :to ORDER BY t") suspend fun between(from: Long, to: Long): List<StressFactEntity>
    @Query("SELECT * FROM stress_facts ORDER BY t DESC LIMIT 1") suspend fun latest(): StressFactEntity?
    @Query("DELETE FROM stress_facts WHERE t < :before") suspend fun prune(before: Long)
}

@Dao
interface EventLogDao {
    @Insert suspend fun insert(e: EventLogEntity)
    @Query("SELECT * FROM event_log ORDER BY t DESC LIMIT :limit") fun observe(limit: Int): Flow<List<EventLogEntity>>
    @Query("SELECT * FROM event_log ORDER BY t DESC LIMIT :limit") suspend fun recent(limit: Int): List<EventLogEntity>
    @Query("DELETE FROM event_log WHERE t < :before") suspend fun prune(before: Long)
}

@Database(
    entities = [
        HrSampleEntity::class, RrEntity::class, MotionMinuteEntity::class, SkinTempEntity::class,
        SleepEntity::class, WorkoutEntity::class, JournalEntity::class, DailyMetricsEntity::class,
        StressFactEntity::class, EventLogEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
abstract class AtriaDatabase : RoomDatabase() {
    abstract fun samples(): SampleDao
    abstract fun sleeps(): SleepDao
    abstract fun workouts(): WorkoutDao
    abstract fun journal(): JournalDao
    abstract fun daily(): DailyDao
    abstract fun stress(): StressDao
    abstract fun log(): EventLogDao

    companion object {
        @Volatile private var instance: AtriaDatabase? = null
        fun get(context: Context): AtriaDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, AtriaDatabase::class.java, "atria.db")
                .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
                .build().also { instance = it }
        }
    }
}
