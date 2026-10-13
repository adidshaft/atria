package com.adidshaft.atria.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.adidshaft.atria.analytics.AthleteProfile
import com.adidshaft.atria.analytics.BiologicalSex
import com.adidshaft.atria.analytics.PersonalBaseline
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private val Context.dataStore by preferencesDataStore("atria_settings")

val AppJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

@Serializable
data class ProfileSettings(
    val name: String = "",
    val age: Int = 30,
    val weightKg: Double = 70.0,
    val heightCm: Double = 175.0,
    val sex: String = BiologicalSex.UNSPECIFIED.name,
    val maxHrOverride: Int? = null,
    val learnedMaxHr: Int? = null,
    val sleepGoalHours: Double = 8.0,
    val stepGoal: Int = 8_000,
    val useMetric: Boolean = true,
) {
    fun toAthlete() = AthleteProfile(name, age, weightKg, heightCm, runCatching { BiologicalSex.valueOf(sex) }.getOrDefault(BiologicalSex.UNSPECIFIED), maxHrOverride ?: learnedMaxHr, sleepGoalHours, stepGoal)
}

@Serializable
data class NotificationSettings(
    val recoveryReady: Boolean = true,
    val strainTarget: Boolean = true,
    val sleepReview: Boolean = true,
    val workoutReview: Boolean = true,
    val morningSummary: Boolean = true,
    val weeklyReport: Boolean = true,
    val healthDeviation: Boolean = true,
    val strapBattery: Boolean = true,
    val bluetoothOff: Boolean = true,
    val fitCheck: Boolean = true,
    val eveningCheckIn: Boolean = true,
    val bedtimeWindDown: Boolean = true,
    val catchUpComplete: Boolean = true,
    val syncNudge: Boolean = true,
)

@Serializable
data class HapticSettings(
    val heartRateZones: Boolean = false,
    val lowBattery: Boolean = true,
    val recoveryReady: Boolean = false,
    val strainTarget: Boolean = true,
    val incomingCalls: Boolean = false,
    /** Buzz the strap itself (0x4F) instead of only the phone. */
    val useStrapMotor: Boolean = true,
)

@Serializable
data class WakeAlarmSettings(
    val enabled: Boolean = false,
    val mode: String = "SMART_WINDOW",
    val hour: Int = 7,
    val minute: Int = 30,
    val strapHaptic: Boolean = true,
)

@Serializable
data class AppSettings(
    val onboardingComplete: Boolean = false,
    val profile: ProfileSettings = ProfileSettings(),
    val notifications: NotificationSettings = NotificationSettings(),
    val haptics: HapticSettings = HapticSettings(),
    val wakeAlarm: WakeAlarmSettings = WakeAlarmSettings(),
    val trackedTags: List<String> = listOf("sleep", "alcohol", "caffeine", "protein", "training", "stress", "hydration", "lateMeal", "morningLight", "meditation"),
    val healthConnectExport: Boolean = false,
    val heartRateBroadcast: Boolean = false,
    val allDayMotion: Boolean = true,
    val autoDetectWorkouts: Boolean = true,
    val autoDetectSleep: Boolean = true,
    /** system | light | dark */
    val theme: String = "system",
    /** default | graphite | mint (alternate launcher icons via activity-alias) */
    val appIcon: String = "default",
    /** built_in (default, fully local) | on_device (Gemini Nano via ML Kit; opt-in) */
    val coachMode: String = "built_in",
    val todayCards: List<String> = listOf("rings", "trio", "live", "brief", "steps", "stress", "sleep", "journal"),
    val anonymousSharing: Boolean = false,
    /** AtriaGlanceSettings: always | workouts | off — what the lock-screen notification shows. */
    val glanceMode: String = "always",
    /** Extra items on the live notification / widgets: zone, steps, battery. */
    val glanceItems: List<String> = listOf("zone", "steps", "battery"),
    /** Opt-in menstrual cycle tracking (AtriaCycleTracking). */
    val cycleTracking: Boolean = false,
    val demoMode: Boolean = false,
    val developerMode: Boolean = false,
)

/** Durable strap/link state (CoreBluetooth restoration identifiers → saved MAC + CDM association). */
@Serializable
data class StrapState(
    val pairedAddress: String? = null,
    val pairedName: String? = null,
    /** BLE address type (0 public, 1 random). WHOOP straps advertise random addresses. */
    val addressType: Int? = null,
    val companionAssociationId: Int? = null,
    val firmware: String? = null,
    val batteryLevel: Int? = null,
    val batteryAt: Long? = null,
    val charging: Boolean = false,
    val clockOffsetSeconds: Long = 0,
    val lastHistorySyncAt: Long? = null,
    val drainedThroughUnix: Long? = null,
    val pendingRecords: Long? = null,
    val historyRecordsSaved: Long = 0,
    val lastConnectedAt: Long? = null,
    val chargeHours: List<Int> = emptyList(),
    /** Onboarding "Start fresh": banked rows older than this are drained and ACKed but not stored. */
    val historyIgnoreBeforeMs: Long? = null,
    /** Stop-capture control: user paused strap collection until they resume it. */
    val capturePaused: Boolean = false,
    /** Un-foolable stall signal: consecutive history slices that saved nothing while a backlog exists. */
    val consecutiveZeroProgressSlices: Int = 0,
    /** When the current strap backlog was first observed (cleared when caught up). */
    val backlogSince: Long? = null,
    /** Set when the backlog is terminally stalled (iOS parked interval). */
    val parkedAt: Long? = null,
    /** Last time a drain slice durably saved rows. */
    val lastProductiveSliceAt: Long? = null,
    /** User-started "catch up faster" boost (auto-reverts when caught up). */
    val catchUpBoost: Boolean = false,
    /** Civil day the 69/01 motion bank was last armed, and firmware back-off. */
    val motionBankArmedDay: Long? = null,
    val motionBankUnsupportedUntil: Long? = null,
)

class SettingsRepository(private val context: Context) {
    private val settingsKey = stringPreferencesKey("app_settings")
    private val strapKey = stringPreferencesKey("strap_state")
    private val baselineKey = stringPreferencesKey("personal_baseline")

    val settings: Flow<AppSettings> = context.dataStore.data.map { p ->
        p[settingsKey]?.let { runCatching { AppJson.decodeFromString<AppSettings>(it) }.getOrNull() } ?: AppSettings()
    }
    val strap: Flow<StrapState> = context.dataStore.data.map { p ->
        p[strapKey]?.let { runCatching { AppJson.decodeFromString<StrapState>(it) }.getOrNull() } ?: StrapState()
    }
    val baseline: Flow<PersonalBaseline> = context.dataStore.data.map { p ->
        p[baselineKey]?.let { runCatching { AppJson.decodeFromString<PersonalBaseline>(it) }.getOrNull() } ?: PersonalBaseline()
    }

    suspend fun current() = settings.first()
    suspend fun currentStrap() = strap.first()
    suspend fun currentBaseline() = baseline.first()

    suspend fun update(transform: (AppSettings) -> AppSettings) {
        context.dataStore.edit { p ->
            val cur = p[settingsKey]?.let { runCatching { AppJson.decodeFromString<AppSettings>(it) }.getOrNull() } ?: AppSettings()
            p[settingsKey] = AppJson.encodeToString(AppSettings.serializer(), transform(cur))
        }
    }

    suspend fun updateStrap(transform: (StrapState) -> StrapState) {
        context.dataStore.edit { p ->
            val cur = p[strapKey]?.let { runCatching { AppJson.decodeFromString<StrapState>(it) }.getOrNull() } ?: StrapState()
            p[strapKey] = AppJson.encodeToString(StrapState.serializer(), transform(cur))
        }
    }

    suspend fun setBaseline(b: PersonalBaseline) {
        context.dataStore.edit { it[baselineKey] = AppJson.encodeToString(PersonalBaseline.serializer(), b) }
    }
}
