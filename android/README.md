# Atria for Android

The Android port of Atria: the same local-only WHOOP 4.0 companion (live heart
rate, sleep, recovery, strain, stress, strap-only steps, journal insights,
workouts, coach), written in Kotlin + Jetpack Compose.

```
android/
  app/src/main/java/com/adidshaft/atria/
    protocol/    WHOOP 4.0 framing, CRC8/CRC32, decoders (2A37, 0x2F history v7–v25, R10, compact IMU 0x33, 0x31 markers, 0x22 range, battery event)
    ble/         StrapManager (GATT queue, autoConnect, notifications, commands), HistoryDrain (persist-before-ACK), MotionAccumulator, Permissions
    analytics/   Strain (Banister TRIMP, 0–21), Recovery (z-blend + logistic), PersonalBaseline, HRV/RMSSD, respiratory rate, stress v4,
                 strap pedometer, sleep detection/stages/need/debt/consistency, smart wake, VO2max, fitness age, training load,
                 journal Welch-t insights, cycle tracking, irregular-rhythm check, sleep planner, Face-Off codec, strength e1RM, reports
    domain/      MetricsEngine (daily recompute, sleep & workout detection), WorkoutRuntime (live workouts, GPS route, sets)
    data/        Room database, DataStore settings, backup/restore, sample data
    platform/    Foreground service, notifications, alerts & haptics, wake alarm, HR broadcaster, companion device, motion context, boot
    health/      Health Connect export
    coach/       On-device coach (Gemini Nano via ML Kit GenAI, deterministic fallback)
    widget/      Glance widgets, Quick Settings tiles
    work/        WorkManager jobs
    diagnostics/ Exit-reason recorder, main-thread watchdog
    ui/          Compose screens (Today, Vitals, Journal, Activity, Coach, Strap, Settings, workout, breathwork, sheets, onboarding)
```

## Build

```bash
cd android && ./gradlew :app:assembleDebug
```

```bash
cd android && ./gradlew :app:testDebugUnitTest
```

Requires JDK 17 and the Android SDK (compileSdk 36, minSdk 28). Unit tests
include the real WHOOP 4.0 history captures and a Face-Off link encoded by
iOS Foundation, so protocol and link compatibility are checked on every run.

## iOS → Android mapping

Everything the iPhone app gets from Apple frameworks has an Android replacement:

| iOS | Android |
|---|---|
| CoreBluetooth central, state restoration, pending connect | `BluetoothGatt` with `autoConnect = true`, serialized GATT op queue, MTU 247, 133/8 reconnect backoff (`ble/StrapManager.kt`) |
| `bluetooth-central` background mode | Foreground service, type `connectedDevice\|health` (`platform/StrapService.kt`) |
| State-restoration relaunch | `CompanionDeviceManager` association + `CompanionDeviceService` presence wake, `BOOT_COMPLETED`, `START_STICKY` |
| BGTaskScheduler (refresh / processing) | WorkManager periodic workers (`work/Scheduling.kt`) |
| Live Activity / Dynamic Island | Ongoing service notification with live BPM; workout notification with chronometer, Pause/End; Android 16 promoted "Live Update" chip |
| WidgetKit | Glance app widgets (Today rings, live HR) |
| Control Center controls (App Intents) | Quick Settings tiles (live HR, start/end workout) |
| App Intents / Siri shortcuts | Static launcher shortcuts (`res/xml/shortcuts.xml`) + `atria://` deep links |
| HealthKit export | Health Connect (sleep with stages, workouts with routes, HR, RHR, **RMSSD** HRV, respiratory rate, calories, steps) |
| UNNotification categories + actions | One notification channel per kind + action buttons (`platform/Notifier.kt`) |
| AlarmKit wake alarm | `AlarmManager.setAlarmClock` hard alarm + minute smart-window check, full-screen alarm activity, strap buzz |
| FoundationModels on-device coach | ML Kit GenAI Prompt API (Gemini Nano on AICore); deterministic coach where unavailable; figures audited against DATA |
| CoreMotion activity (driving vs workout) | Activity Recognition transitions (IN_VEHICLE) |
| CoreLocation workout routes | Fused location provider; foreground service gains the `location` type during route workouts |
| MapKit route map | osmdroid (OpenStreetMap, no API key, works without Google Play) |
| CBPeripheralManager HR broadcast | `BluetoothGattServer` + `BluetoothLeAdvertiser` standard Heart Rate Service |
| CallKit `CXCallObserver` haptic | `TelephonyCallback` → strap motor buzz (0x4F) |
| UIFeedbackGenerator haptics | `VibrationEffect`; most alerts can also buzz the strap itself |
| PHPicker / share sheet / ImageRenderer | Photo Picker, `ACTION_SEND` via FileProvider, bitmap-rendered share card |
| Lock Screen & Widgets settings (AtriaGlanceSettings) | Settings › Lock screen & widgets: Always / Workouts / Off, plus zone/steps/battery items on the notification and widgets |
| Device-use journal (lock/unlock) | `USER_PRESENT` / `SCREEN_OFF` receiver; ≥ 10 min phone use excludes those minutes from sleep detection |
| Research tools (diagnosis report, IMU diagnostics, step calibration, sensor-reference capture, research bundle) | Developer screen (`atria://developer`); research bundle is consent-first and queue-only, exactly like iOS (no network transport) |
| Alternate app icons | `activity-alias` launcher entries toggled at runtime |
| UserDefaults / JSON stores | DataStore + Room (WAL) |
| MetricKit diagnostics, hang watchdog | `ApplicationExitInfo` + main-thread watchdog into the on-device event log |
| App Group container | Single process; widgets and tiles read the same Room database |
| iCloud-excluded, local-only data | `allowBackup=false` + data-extraction rules exclude everything; ML Kit's telemetry upload backend is excluded at build time |

## Android-specific behaviour (no iOS equivalent)

- **Foreground-service start rules.** Android 12+ refuses to start a
  foreground service from the background. Atria starts it from the visible
  activity, from boot, or under the companion-device exemption, and answers
  every start with `startForeground()`.
- **Battery optimisation.** OEM battery savers can kill BLE services, so the
  Strap screen and onboarding offer the "ignore battery optimisations" request.
- **Permissions are split.** Nearby devices, notifications, physical activity,
  location, phone state, exact alarms and Health Connect are asked separately,
  each only when its feature is turned on.
- **Strap-motor alerts.** Zone changes, strain target, recovery, incoming calls
  and the smart alarm can buzz the strap (0x4F), not only the phone.

## Status

- Protocol, analytics, history-drain state machine and device-use journal:
  unit-tested (39 tests), including real strap captures and an iOS-encoded
  Face-Off link.
- Every iOS source file is mapped to its Android counterpart (or the reason
  none is needed) in [PARITY.md](PARITY.md).
- UI, service, notifications, widgets, shortcuts, deep links, sample data and
  the workout lifecycle: exercised on an Android 16 emulator.
- **Bluetooth verified end to end against a simulated strap** (`strapsim/`, a
  WHOOP 4.0 GATT peripheral run on a second emulator over the emulators'
  shared virtual radio): scan, connect, MTU, five CCCDs, GET_CLOCK, 03/6A IMU
  enable, GET_DATA_RANGE, three history pages each persisted then ACKed with
  the exact END token, COMPLETE, live 2A37 HR + RR, 2A19 battery, firmware read,
  152-byte compact IMU frames → strap-counted steps, 0x4F buzz, and recovery
  from a 40 s range loss with the screen off.
- That harness found two Android-only defects, both fixed: a MAC string
  rebuilds the device with the *public* address type, so connecting to the
  strap's random address failed (GATT 135); and Android `autoConnect` cannot
  follow a rotated private address (iOS hides this behind its peripheral
  identifier), so reconnection now uses a filtered reconnect scan that adopts a
  rotated address carrying the same name and WHOOP service.
- Still recommended: one run on a physical WHOOP 4.0 + Android phone, since the
  simulator implements the documented protocol, not the strap firmware.

### Bluetooth test harness

```bash
cd android && ./gradlew :strapsim:assembleDebug :app:assembleDebug
```

Install `strapsim` on one emulator and Atria on another (API 33+ images share
netsim Bluetooth), start "WHOOP 4.0 Simulator", then in Atria open Strap ›
Scan manually › Connect. The simulator logs every command it receives
(`adb logcat -s StrapSim`).
