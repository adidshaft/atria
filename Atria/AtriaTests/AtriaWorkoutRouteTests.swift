import XCTest
import CoreLocation
@testable import Atria

final class AtriaWorkoutRouteTests: XCTestCase {
    func testRouteWorkoutIsMapFirstWithPinnedGlanceableMetricsAndActions() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift"), encoding: .utf8)
        let mainStart = try XCTUnwrap(source.range(of: "struct AtriaLiveWorkoutView: View"))
        let mainEnd = try XCTUnwrap(source.range(of: "private struct AtriaLiveWorkoutBackdrop",
                                                range: mainStart.upperBound..<source.endIndex))
        let main = String(source[mainStart.lowerBound..<mainEnd.lowerBound])
        let routeStart = try XCTUnwrap(main.range(of: "private var routeWorkoutContent: some View"))
        let standardStart = try XCTUnwrap(main.range(of: "private var standardWorkoutContent: some View",
                                                     range: routeStart.upperBound..<main.endIndex))
        let actionsStart = try XCTUnwrap(main.range(of: "private var routeWorkoutActions: some View",
                                                    range: standardStart.upperBound..<main.endIndex))
        let headerStart = try XCTUnwrap(main.range(of: "private var header: some View",
                                                   range: actionsStart.upperBound..<main.endIndex))
        let route = String(main[routeStart.lowerBound..<standardStart.lowerBound])
        let standard = String(main[standardStart.lowerBound..<actionsStart.lowerBound])
        let actions = String(main[actionsStart.lowerBound..<headerStart.lowerBound])

        XCTAssertTrue(main.contains("if activityType.supportsRouteRecording"))
        XCTAssertTrue(route.contains("AtriaLiveWorkoutRouteCard(routeRecorder: routeRecorder)"))
        XCTAssertTrue(route.contains("AtriaLiveWorkoutRouteMetricsHUD(pulseStore: pulseStore,"))
        XCTAssertTrue(route.contains("routeWorkoutActions"))
        XCTAssertTrue(route.contains("Spacer(minLength: 24)"),
                      "The map must own the available center of the route screen")
        XCTAssertFalse(route.contains("ScrollView"),
                       "Outdoor metrics and controls must not scroll off the live map")
        XCTAssertTrue(actions.contains("Label(isPaused ? \"Resume\" : \"Pause\""))
        XCTAssertTrue(actions.contains("Label(\"End\", systemImage: \"stop.fill\")"))
        XCTAssertTrue(actions.contains("Button(role: .destructive, action: endWorkout)"))
        XCTAssertTrue(actions.contains("GlassEffectContainer(spacing: 10)"))

        XCTAssertTrue(standard.contains("ScrollView(showsIndicators: false)"))
        XCTAssertTrue(standard.contains("AtriaLiveWorkoutHeartBlock(pulseStore: pulseStore,"))
        XCTAssertTrue(standard.contains("AtriaLiveWorkoutStrainGuidance(metricProjection: metricProjection,"))
        XCTAssertTrue(standard.contains("workoutActionsCard"))
        XCTAssertTrue(standard.contains("stopButton"),
                      "Strength and non-route workout behavior must remain intact")
    }

    func testRouteHUDKeepsThreeDigitHeartRateOnOneLineAndExposesEveryLiveMetric() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift"), encoding: .utf8)
        let hudStart = try XCTUnwrap(source.range(of: "private struct AtriaLiveWorkoutRouteMetricsHUD: View"))
        let hudEnd = try XCTUnwrap(source.range(of: "private struct AtriaLiveWorkoutHeartBlock: View",
                                               range: hudStart.upperBound..<source.endIndex))
        let hud = String(source[hudStart.lowerBound..<hudEnd.lowerBound])

        XCTAssertTrue(hud.contains("@ObservedObject var pulseStore"))
        XCTAssertTrue(hud.contains("Text(heartRate > 0 ? \"\\(heartRate)\" : \"--\")"))
        XCTAssertTrue(hud.contains(".monospacedDigit()"))
        XCTAssertTrue(hud.contains(".lineLimit(1)"))
        XCTAssertTrue(hud.contains(".minimumScaleFactor(0.58)"))
        XCTAssertTrue(hud.contains(".layoutPriority(3)"))
        XCTAssertTrue(hud.contains("metricProjection.steps.hudText"))
        XCTAssertTrue(hud.contains("metricProjection.steps.accessibilityText"))
        XCTAssertTrue(hud.contains("metricProjection.strainHUDText"))
        XCTAssertTrue(hud.contains("metricProjection.activeCalories"))
        XCTAssertTrue(hud.contains("Text(zoneText)"))
        XCTAssertTrue(hud.contains(".accessibilityLabel(\"Heart rate"))
        XCTAssertTrue(hud.contains(".atriaWorkoutGlassSurface(cornerRadius: 24"),
                      "The pinned map overlay should use the native Liquid Glass surface")
    }

    func testRouteObservationIsScopedToMapLeaf() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let liveSource = try String(contentsOf: sourceDirectory.appendingPathComponent("AtriaLiveWorkoutView.swift"),
                                    encoding: .utf8)
        let homeSource = try String(contentsOf: sourceDirectory.appendingPathComponent("AtriaHomeView.swift"),
                                    encoding: .utf8)
        let mainStart = try XCTUnwrap(liveSource.range(of: "struct AtriaLiveWorkoutView: View"))
        let mainEnd = try XCTUnwrap(liveSource.range(of: "private struct AtriaLiveWorkoutBackdrop",
                                                     range: mainStart.upperBound..<liveSource.endIndex))
        let mainView = String(liveSource[mainStart.lowerBound..<mainEnd.lowerBound])

        XCTAssertTrue(liveSource.contains("private struct AtriaLiveWorkoutRouteCard: View"))
        XCTAssertTrue(liveSource.contains("@ObservedObject var routeRecorder: AtriaWorkoutRouteRecorder"))
        XCTAssertTrue(mainView.contains("let routeRecorder: AtriaWorkoutRouteRecorder"))
        XCTAssertFalse(mainView.contains("@ObservedObject var routeRecorder"))
        XCTAssertTrue(homeSource.contains("let workoutRouteRecorder: AtriaWorkoutRouteRecorder"),
                      "Home must hold the root-owned recorder without observing its GPS publishes")
        XCTAssertFalse(homeSource.contains("@ObservedObject var workoutRouteRecorder"))
        XCTAssertFalse(homeSource.contains("@StateObject private var workoutRouteRecorder: AtriaWorkoutRouteRecorder"))
    }

    func testSetLoggingAffordancesAreGatedToExerciseWorkouts() throws {
        XCTAssertTrue(AtriaWorkoutActivityType.strength.supportsExerciseSelection)
        XCTAssertTrue(AtriaWorkoutActivityType.hiit.supportsExerciseSelection)
        XCTAssertFalse(AtriaWorkoutActivityType.walking.supportsExerciseSelection)
        XCTAssertFalse(AtriaWorkoutActivityType.running.supportsExerciseSelection)
        XCTAssertFalse(AtriaWorkoutActivityType.yoga.supportsExerciseSelection)

        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let actionsStart = try XCTUnwrap(source.range(of: "private var workoutActionsCard: some View"))
        let actionsEnd = try XCTUnwrap(source.range(of: "private func loggedSetRow",
                                                    range: actionsStart.upperBound..<source.endIndex))
        let actions = String(source[actionsStart.lowerBound..<actionsEnd.lowerBound])
        XCTAssertTrue(actions.contains("if activityType.supportsExerciseSelection"))
        XCTAssertTrue(actions.contains("if activityType.supportsExerciseSelection, !loggedSets.isEmpty"))
        XCTAssertTrue(actions.contains("if activityType.supportsExerciseSelection, let restTimerEndsAt"))
    }

    func testLiveWorkoutUsesTwoDeStackedPerformanceSurfaces() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let mainStart = try XCTUnwrap(source.range(of: "struct AtriaLiveWorkoutView: View"))
        let mainEnd = try XCTUnwrap(source.range(of: "private struct AtriaLiveWorkoutBackdrop",
                                                range: mainStart.upperBound..<source.endIndex))
        let main = String(source[mainStart.lowerBound..<mainEnd.lowerBound])

        XCTAssertTrue(main.contains("AtriaLiveWorkoutHeartBlock(pulseStore: pulseStore,"))
        XCTAssertTrue(main.contains("metricProjection: metricProjection"))
        XCTAssertTrue(main.contains("AtriaLiveWorkoutStrainGuidance(metricProjection: metricProjection,"))
        XCTAssertFalse(main.contains("AtriaLiveWorkoutZoneCard("))
        XCTAssertFalse(main.contains("AtriaLiveWorkoutStatsRow("))

        let pulseStart = try XCTUnwrap(source.range(of: "private struct AtriaLiveWorkoutHeartBlock: View"))
        let performanceStart = try XCTUnwrap(source.range(of: "private struct AtriaLiveWorkoutStrainGuidance: View",
                                                         range: pulseStart.upperBound..<source.endIndex))
        let pulse = String(source[pulseStart.lowerBound..<performanceStart.lowerBound])
        XCTAssertTrue(pulse.contains("ForEach(HRZone.allCases"))
        XCTAssertFalse(pulse.contains("sessionSampleCount"),
                       "the heart block must not observe hidden broad sample-count churn")

        let pickerStart = try XCTUnwrap(source.range(of: "/// Pre-workout (or mid-workout) target picker",
                                                    range: performanceStart.upperBound..<source.endIndex))
        let performance = String(source[performanceStart.lowerBound..<pickerStart.lowerBound])
        XCTAssertTrue(performance.contains("metricProjection.activeCalories"))
        XCTAssertTrue(performance.contains("metricProjection.strain"))
        XCTAssertFalse(performance.contains("heroStore.state.strain"),
                       "the live workout must never show nonlinear day strain as workout strain")
        XCTAssertFalse(performance.contains("metricPill"))
    }

    func testLiveWorkoutHeartRateNeverWrapsAcrossAppAccessoryAndLockScreen() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let liveSource = try String(contentsOf: appDirectory.appendingPathComponent("AtriaLiveWorkoutView.swift"),
                                    encoding: .utf8)
        let homeSource = try String(contentsOf: appDirectory.appendingPathComponent("AtriaHomeView.swift"),
                                    encoding: .utf8)
        let widgetSource = try String(contentsOf: appDirectory.deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        let heartStart = try XCTUnwrap(liveSource.range(of: "private struct AtriaLiveWorkoutHeartBlock: View"))
        let heartEnd = try XCTUnwrap(liveSource.range(of: "private struct AtriaLiveWorkoutStrainGuidance: View",
                                                     range: heartStart.upperBound..<liveSource.endIndex))
        let heart = String(liveSource[heartStart.lowerBound..<heartEnd.lowerBound])
        XCTAssertTrue(heart.contains(".monospacedDigit()"))
        XCTAssertTrue(heart.contains(".lineLimit(1)"))
        XCTAssertTrue(heart.contains(".minimumScaleFactor(0.52)"))
        XCTAssertTrue(heart.contains(".layoutPriority(3)"))
        XCTAssertTrue(heart.contains(".accessibilityLabel(\"Heart rate"))

        let accessoryStart = try XCTUnwrap(homeSource.range(of: "private struct AtriaLiveWorkoutTabAccessory: View"))
        let accessoryEnd = try XCTUnwrap(homeSource.range(of: "private struct AtriaStandByOverlay: View",
                                                         range: accessoryStart.upperBound..<homeSource.endIndex))
        let accessory = String(homeSource[accessoryStart.lowerBound..<accessoryEnd.lowerBound])
        XCTAssertTrue(accessory.contains(".lineLimit(1)"))
        XCTAssertTrue(accessory.contains(".minimumScaleFactor(0.62)"))
        XCTAssertTrue(accessory.contains(".layoutPriority(3)"))
        XCTAssertTrue(accessory.contains("presentation.accessibilityLabel"))

        let activityStart = try XCTUnwrap(widgetSource.range(of: "struct AtriaLiveActivityWidget: Widget"))
        let activityEnd = try XCTUnwrap(widgetSource.range(of: "private func liveActivityBatteryText",
                                                           range: activityStart.upperBound..<widgetSource.endIndex))
        let island = String(widgetSource[activityStart.lowerBound..<activityEnd.lowerBound])
        XCTAssertTrue(island.contains(".minimumScaleFactor(0.62)"))
        XCTAssertTrue(island.contains(".minimumScaleFactor(0.55)"))
        XCTAssertTrue(island.contains("Heart rate \\(context.state.heartRate) beats per minute"))

        let lockStart = try XCTUnwrap(widgetSource.range(of: "private struct AtriaLiveActivityLockScreenView"))
        let lockEnd = try XCTUnwrap(widgetSource.range(of: "private func elapsedText",
                                                       range: lockStart.upperBound..<widgetSource.endIndex))
        let lock = String(widgetSource[lockStart.lowerBound..<lockEnd.lowerBound])
        XCTAssertTrue(lock.contains(".minimumScaleFactor(0.58)"))
        XCTAssertTrue(lock.contains(".layoutPriority(3)"))
        XCTAssertTrue(lock.contains(".accessibilityElement(children: .ignore)"))
    }

    func testActiveRouteCheckpointRoundTripsAndClearsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-route-checkpoint-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("active.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 50_000)
        let point = AtriaWorkoutRoute.Point(latitude: 28.6139,
                                            longitude: 77.2090,
                                            altitude: 216,
                                            timestamp: start.addingTimeInterval(10),
                                            horizontalAccuracy: 6)
        let checkpoint = AtriaActiveWorkoutRouteCheckpoint(
            schema: AtriaActiveWorkoutRouteCheckpoint.schema,
            activityType: AtriaWorkoutActivityType.running.rawValue,
            startedAt: start,
            finalizedAt: nil,
            points: [point],
            distanceMeters: 42,
            elevationGainMeters: 3,
            pauseStartedAt: start.addingTimeInterval(20),
            accumulatedPauseDuration: 12,
            updatedAt: start.addingTimeInterval(30)
        )

        try AtriaActiveWorkoutRouteCheckpointStore.save(checkpoint, to: url)
        XCTAssertEqual(AtriaActiveWorkoutRouteCheckpointStore.load(from: url), checkpoint)
        AtriaActiveWorkoutRouteCheckpointStore.clear(at: url)
        XCTAssertNil(AtriaActiveWorkoutRouteCheckpointStore.load(from: url))
    }

    func testIncrementalRouteCheckpointKeepsMetadataBoundedAndRestoresEveryPoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-incremental-route-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("active.json")
        let journalURL = directory.appendingPathComponent("active.points.ndjson")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 70_000)
        var points: [AtriaWorkoutRoute.Point] = []
        points.reserveCapacity(5_100)
        for index in 0..<5_100 {
            let offset = Double(index)
            let point = AtriaWorkoutRoute.Point(
                latitude: 28.60 + offset * 0.00001,
                longitude: 77.20 + offset * 0.00001,
                altitude: 200 + Double(index % 8),
                timestamp: start.addingTimeInterval(offset * 3),
                horizontalAccuracy: 5,
                verticalAccuracy: 4,
                startsNewSegment: index == 0
            )
            points.append(point)
        }
        func checkpoint(pointCount: Int, updatedAt: Date) -> AtriaActiveWorkoutRouteCheckpoint {
            AtriaActiveWorkoutRouteCheckpoint(
                schema: AtriaActiveWorkoutRouteCheckpoint.schema,
                activityType: AtriaWorkoutActivityType.running.rawValue,
                startedAt: start,
                finalizedAt: nil,
                points: [],
                distanceMeters: Double(pointCount) * 3,
                elevationGainMeters: 18,
                pauseStartedAt: nil,
                accumulatedPauseDuration: 0,
                updatedAt: updatedAt,
                coverageStartedAt: start
            )
        }

        let initialCount = 5_000
        try AtriaActiveWorkoutRouteCheckpointStore.saveIncremental(
            checkpoint(pointCount: initialCount, updatedAt: start.addingTimeInterval(15_000)),
            appendedPoints: Array(points.prefix(initialCount)),
            expectedPersistedPointCount: 0,
            resetJournal: true,
            to: url
        )
        let metadataBytes = try Data(contentsOf: url).count
        XCTAssertLessThan(metadataBytes, 2_000,
                          "Atomic metadata must stay O(1) as a route grows")
        XCTAssertEqual(AtriaActiveWorkoutRouteCheckpointStore.load(from: url)?.points,
                       Array(points.prefix(initialCount)))

        // Simulate bytes appended before a metadata commit. The next write must
        // truncate to the last committed byte boundary before adding its suffix.
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("stale-uncommitted-tail\n".utf8))
        try handle.close()

        try AtriaActiveWorkoutRouteCheckpointStore.saveIncremental(
            checkpoint(pointCount: points.count, updatedAt: start.addingTimeInterval(15_300)),
            appendedPoints: Array(points.suffix(from: initialCount)),
            expectedPersistedPointCount: initialCount,
            resetJournal: false,
            to: url
        )
        let restored = try XCTUnwrap(AtriaActiveWorkoutRouteCheckpointStore.load(from: url))
        XCTAssertEqual(restored.points, points)
        XCTAssertEqual(restored.distanceMeters, Double(points.count) * 3)
        XCTAssertLessThan(try Data(contentsOf: url).count, 2_000)
    }

    func testLiveRoutePreviewStaysBoundedWithoutLosingEndpoints() {
        let limit = 64
        var preview: [[CLLocationCoordinate2D]] = []
        for index in 0..<20_000 {
            preview = AtriaWorkoutRouteRecorder.previewSegments(
                byAppending: CLLocationCoordinate2D(latitude: Double(index),
                                                     longitude: -Double(index)),
                startsNewSegment: index == 0,
                to: preview,
                limit: limit
            )
            XCTAssertLessThanOrEqual(preview.reduce(0, { $0 + $1.count }), limit)
        }

        XCTAssertEqual(preview.first?.first?.latitude, 0)
        XCTAssertEqual(preview.last?.last?.latitude, 19_999)
        XCTAssertEqual(preview.last?.last?.longitude, -19_999)
    }

    func testLiveRoutePreviewKeepsPauseSegmentsSeparateWhileCompacting() {
        let limit = 40
        var preview: [[CLLocationCoordinate2D]] = []
        for index in 0..<160 {
            preview = AtriaWorkoutRouteRecorder.previewSegments(
                byAppending: CLLocationCoordinate2D(latitude: Double(index),
                                                     longitude: Double(index)),
                startsNewSegment: index == 0 || index == 80,
                to: preview,
                limit: limit
            )
        }

        XCTAssertEqual(preview.count, 2,
                       "Pause/resume must remain two polylines instead of inventing a connecting path")
        XCTAssertLessThanOrEqual(preview.reduce(0, { $0 + $1.count }), limit)
        XCTAssertEqual(preview[0].first?.latitude, 0)
        XCTAssertEqual(preview[0].last?.latitude, 79)
        XCTAssertEqual(preview[1].first?.latitude, 80)
        XCTAssertEqual(preview[1].last?.latitude, 159)
    }

    func testLiveRouteMapConsumesPrecomputedBoundedCoordinates() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let liveSource = try String(contentsOf: sourceDirectory.appendingPathComponent("AtriaLiveWorkoutView.swift"),
                                    encoding: .utf8)
        let routeSource = try String(contentsOf: sourceDirectory.appendingPathComponent("AtriaWorkoutRoute.swift"),
                                     encoding: .utf8)

        let mapStart = try XCTUnwrap(liveSource.range(of: "private struct AtriaLiveWorkoutRouteMap"))
        let cardStart = try XCTUnwrap(liveSource.range(of: "private struct AtriaLiveWorkoutRouteCard",
                                                      range: mapStart.upperBound..<liveSource.endIndex))
        let mapSource = String(liveSource[mapStart.lowerBound..<cardStart.lowerBound])
        XCTAssertTrue(mapSource.contains("MapPolyline(coordinates: coordinates)"))
        XCTAssertTrue(mapSource.contains("Map(position: $cameraPosition)"))
        XCTAssertTrue(mapSource.contains("UserAnnotation()"))
        XCTAssertTrue(mapSource.contains(".userLocation("))
        XCTAssertFalse(mapSource.contains("points.map"))
        XCTAssertTrue(routeSource.contains("maximumLivePreviewPointCount = 512"))
        XCTAssertTrue(mapSource.contains("ForEach(Array(segments.enumerated())"))
        XCTAssertTrue(routeSource.contains("snapshot.previewSegments = previewSegments"))
        XCTAssertFalse(routeSource.contains("snapshot.points = points"))
    }

    func testFinalizedRouteCheckpointRetainsExactEndForSparseWorkoutRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-final-route-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("final.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 60_000)
        let end = start.addingTimeInterval(50 * 60)
        let checkpoint = AtriaActiveWorkoutRouteCheckpoint(
            schema: AtriaActiveWorkoutRouteCheckpoint.schema,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            startedAt: start,
            finalizedAt: end,
            points: [
                AtriaWorkoutRoute.Point(latitude: 28.61, longitude: 77.20, altitude: 210,
                                        timestamp: start, horizontalAccuracy: 5),
                AtriaWorkoutRoute.Point(latitude: 28.62, longitude: 77.21, altitude: 212,
                                        timestamp: end, horizontalAccuracy: 5),
            ],
            distanceMeters: 1_800,
            elevationGainMeters: 18,
            pauseStartedAt: nil,
            accumulatedPauseDuration: 120,
            updatedAt: end
        )

        try AtriaActiveWorkoutRouteCheckpointStore.save(checkpoint, to: url)
        let restored = try XCTUnwrap(AtriaActiveWorkoutRouteCheckpointStore.load(from: url))
        XCTAssertEqual(restored.finalizedAt, end)
        XCTAssertEqual(restored.points.count, 2)
        XCTAssertEqual(restored.accumulatedPauseDuration, 120)
    }

    func testEndedWorkoutRecoversActiveRouteCheckpointFromCrashWindow() throws {
        let start = Date(timeIntervalSince1970: 70_000)
        let end = start.addingTimeInterval(40 * 60)
        let pauseStart = end.addingTimeInterval(-90)
        let checkpoint = AtriaActiveWorkoutRouteCheckpoint(
            schema: AtriaActiveWorkoutRouteCheckpoint.schema,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            startedAt: start,
            finalizedAt: nil,
            points: [
                AtriaWorkoutRoute.Point(latitude: 28.61, longitude: 77.20, altitude: 210,
                                        timestamp: start.addingTimeInterval(10), horizontalAccuracy: 5),
                AtriaWorkoutRoute.Point(latitude: 28.62, longitude: 77.21, altitude: 212,
                                        timestamp: end.addingTimeInterval(-5), horizontalAccuracy: 5),
            ],
            distanceMeters: 1_600,
            elevationGainMeters: 16,
            pauseStartedAt: pauseStart,
            accumulatedPauseDuration: 60,
            updatedAt: end.addingTimeInterval(-2)
        )

        let recovered = try XCTUnwrap(AtriaWorkoutRouteRecorder.recoveredDraft(
            from: checkpoint,
            startedAt: start,
            activityType: .walking,
            endedAt: end
        ))

        XCTAssertEqual(recovered.startedAt, start)
        XCTAssertEqual(recovered.endedAt, end)
        XCTAssertEqual(recovered.points, checkpoint.points)
        XCTAssertEqual(recovered.distanceMeters, 1_600)
        XCTAssertEqual(recovered.pausedDuration, 150, accuracy: 0.001)
    }

    func testEndedWorkoutDoesNotRecoverAnotherRouteCheckpoint() {
        let start = Date(timeIntervalSince1970: 80_000)
        let end = start.addingTimeInterval(30 * 60)
        let checkpoint = AtriaActiveWorkoutRouteCheckpoint(
            schema: AtriaActiveWorkoutRouteCheckpoint.schema,
            activityType: AtriaWorkoutActivityType.running.rawValue,
            startedAt: start,
            finalizedAt: nil,
            points: [
                AtriaWorkoutRoute.Point(latitude: 28.61, longitude: 77.20, altitude: 210,
                                        timestamp: start, horizontalAccuracy: 5),
                AtriaWorkoutRoute.Point(latitude: 28.62, longitude: 77.21, altitude: 212,
                                        timestamp: end, horizontalAccuracy: 5),
            ],
            distanceMeters: 2_000,
            elevationGainMeters: 10,
            pauseStartedAt: nil,
            accumulatedPauseDuration: 0,
            updatedAt: end
        )

        XCTAssertNil(AtriaWorkoutRouteRecorder.recoveredDraft(
            from: checkpoint,
            startedAt: start,
            activityType: .walking,
            endedAt: end
        ))
    }

    func testBackgroundLocationBatchUsesWorkoutWindowInsteadOfDeliveryAge() {
        let workoutStart = Date(timeIntervalSince1970: 10_000)
        let deliveredAt = workoutStart.addingTimeInterval(20 * 60)

        XCTAssertTrue(AtriaWorkoutRouteRecorder.shouldAcceptRouteLocation(
            horizontalAccuracy: 8,
            timestamp: workoutStart.addingTimeInterval(2 * 60),
            workoutStartedAt: workoutStart,
            deliveredAt: deliveredAt
        ), "A valid location batched in the background must not be discarded merely because delivery was delayed")
        XCTAssertFalse(AtriaWorkoutRouteRecorder.shouldAcceptRouteLocation(
            horizontalAccuracy: 8,
            timestamp: workoutStart.addingTimeInterval(-60),
            workoutStartedAt: workoutStart,
            deliveredAt: deliveredAt
        ))
        XCTAssertFalse(AtriaWorkoutRouteRecorder.shouldAcceptRouteLocation(
            horizontalAccuracy: 80,
            timestamp: deliveredAt,
            workoutStartedAt: workoutStart,
            deliveredAt: deliveredAt
        ))
        XCTAssertFalse(AtriaWorkoutRouteRecorder.shouldAcceptRouteLocation(
            horizontalAccuracy: 8,
            timestamp: deliveredAt.addingTimeInterval(30),
            workoutStartedAt: workoutStart,
            deliveredAt: deliveredAt
        ))
    }

    func testReducedAccuracyRequestsTemporaryPreciseLocationOnlyWhenAuthorized() {
        XCTAssertTrue(AtriaWorkoutRouteRecorder.shouldRequestTemporaryFullAccuracy(
            authorizationStatus: .authorizedWhenInUse,
            accuracyAuthorization: .reducedAccuracy
        ))
        XCTAssertFalse(AtriaWorkoutRouteRecorder.shouldRequestTemporaryFullAccuracy(
            authorizationStatus: .authorizedWhenInUse,
            accuracyAuthorization: .fullAccuracy
        ))
        XCTAssertFalse(AtriaWorkoutRouteRecorder.shouldRequestTemporaryFullAccuracy(
            authorizationStatus: .denied,
            accuracyAuthorization: .reducedAccuracy
        ))
    }

    func testAveragePaceUsesRecordedDistanceAndElapsedTime() {
        let start = Date(timeIntervalSince1970: 1_000)
        let route = AtriaWorkoutRoute(id: "route",
                                      workoutID: "workout",
                                      activityType: AtriaWorkoutActivityType.running.rawValue,
                                      startedAt: start,
                                      endedAt: start.addingTimeInterval(600),
                                      points: [],
                                      distanceMeters: 2_000,
                                      elevationGainMeters: 12)

        XCTAssertEqual(route.averagePaceSecondsPerKilometer, 300)
    }

    func testPaceStaysUnknownForGpsNoiseDistance() {
        let start = Date(timeIntervalSince1970: 1_000)
        let route = AtriaWorkoutRoute(id: "route",
                                      workoutID: "workout",
                                      activityType: AtriaWorkoutActivityType.walking.rawValue,
                                      startedAt: start,
                                      endedAt: start.addingTimeInterval(120),
                                      points: [],
                                      distanceMeters: 42,
                                      elevationGainMeters: 0)

        XCTAssertNil(route.averagePaceSecondsPerKilometer)
    }

    func testAveragePaceExcludesManuallyPausedTime() {
        let start = Date(timeIntervalSince1970: 1_000)
        let route = AtriaWorkoutRoute(id: "route",
                                      workoutID: "workout",
                                      activityType: AtriaWorkoutActivityType.running.rawValue,
                                      startedAt: start,
                                      endedAt: start.addingTimeInterval(900),
                                      points: [],
                                      distanceMeters: 2_000,
                                      elevationGainMeters: 12,
                                      pausedDuration: 300)

        XCTAssertEqual(route.movingDuration, 600)
        XCTAssertEqual(route.averagePaceSecondsPerKilometer, 300)
    }

    func testPaceStartsWhenRouteCoverageActuallyBegins() {
        let start = Date(timeIntervalSince1970: 1_000)
        let route = AtriaWorkoutRoute(id: "route",
                                      workoutID: "workout",
                                      activityType: AtriaWorkoutActivityType.running.rawValue,
                                      startedAt: start,
                                      endedAt: start.addingTimeInterval(900),
                                      coverageStartedAt: start.addingTimeInterval(300),
                                      points: [],
                                      distanceMeters: 2_000,
                                      elevationGainMeters: 0)

        XCTAssertEqual(route.movingDuration, 600)
        XCTAssertEqual(route.averagePaceSecondsPerKilometer, 300)
    }

    func testRouteDeltaRejectsJitterAndActivitySpecificTeleport() {
        XCTAssertFalse(AtriaWorkoutRouteRecorder.shouldAccumulateRouteDelta(
            distance: 5,
            seconds: 3,
            previousAccuracy: 20,
            currentAccuracy: 20,
            activityType: .walking
        ))
        XCTAssertFalse(AtriaWorkoutRouteRecorder.shouldAccumulateRouteDelta(
            distance: 70,
            seconds: 5,
            previousAccuracy: 5,
            currentAccuracy: 5,
            activityType: .walking
        ))
        XCTAssertTrue(AtriaWorkoutRouteRecorder.shouldAccumulateRouteDelta(
            distance: 30,
            seconds: 5,
            previousAccuracy: 5,
            currentAccuracy: 5,
            activityType: .cycling
        ))
    }

    func testGPXUsesSeparateTrackSegmentsAcrossPauseBoundary() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            AtriaWorkoutRoute.Point(latitude: 28.610, longitude: 77.200, altitude: 200,
                                    timestamp: start, horizontalAccuracy: 5, startsNewSegment: true),
            AtriaWorkoutRoute.Point(latitude: 28.611, longitude: 77.201, altitude: 201,
                                    timestamp: start.addingTimeInterval(30), horizontalAccuracy: 5),
            AtriaWorkoutRoute.Point(latitude: 28.620, longitude: 77.210, altitude: 202,
                                    timestamp: start.addingTimeInterval(300), horizontalAccuracy: 5,
                                    startsNewSegment: true),
        ]
        let route = AtriaWorkoutRoute(id: "segmented-route",
                                      workoutID: "segmented-route",
                                      activityType: AtriaWorkoutActivityType.walking.rawValue,
                                      startedAt: start,
                                      endedAt: start.addingTimeInterval(600),
                                      points: points,
                                      distanceMeters: 500,
                                      elevationGainMeters: 2)
        let url = try XCTUnwrap(AtriaWorkoutRouteStore.gpxURL(for: route))
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(xml.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertEqual(xml.components(separatedBy: "</trkseg>").count - 1, 2)
    }

    @MainActor
    func testActivityEditClipsAndReconcilesRouteThenIndoorTypeDeletesIt() throws {
        let oldID = "route-edit-old-\(UUID().uuidString)"
        let newID = "route-edit-new-\(UUID().uuidString)"
        defer {
            AtriaWorkoutRouteStore.delete(workoutID: oldID)
            AtriaWorkoutRouteStore.delete(workoutID: newID)
        }
        let start = Date(timeIntervalSince1970: 10_000)
        let points = (0..<5).map { index in
            AtriaWorkoutRoute.Point(latitude: 28.61 + Double(index) * 0.0001,
                                    longitude: 77.20,
                                    altitude: 200,
                                    timestamp: start.addingTimeInterval(Double(index) * 30),
                                    horizontalAccuracy: 5,
                                    verticalAccuracy: 5,
                                    startsNewSegment: index == 0)
        }
        let draft = AtriaWorkoutRouteRecorder.Draft(activityType: .walking,
                                                    startedAt: start,
                                                    endedAt: start.addingTimeInterval(120),
                                                    coverageStartedAt: start,
                                                    points: points,
                                                    distanceMeters: 44,
                                                    elevationGainMeters: 0,
                                                    pausedDuration: 0)
        XCTAssertNotNil(AtriaWorkoutRouteStore.save(draft, workoutID: oldID))

        XCTAssertNoThrow(try AtriaWorkoutRouteStore.reconcile(from: oldID,
                                                              to: newID,
                                                              activityType: .running,
                                                              start: start.addingTimeInterval(30),
                                                              end: start.addingTimeInterval(90)).get())
        let edited = try XCTUnwrap(AtriaWorkoutRouteStore.load(workoutID: newID))
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: oldID))
        XCTAssertEqual(edited.activityType, AtriaWorkoutActivityType.running.rawValue)
        XCTAssertEqual(edited.points.count, 3)
        XCTAssertTrue(edited.points[0].startsNewSegment ?? false)
        XCTAssertEqual(edited.startedAt, start.addingTimeInterval(30))
        XCTAssertEqual(edited.endedAt, start.addingTimeInterval(90))

        XCTAssertNoThrow(try AtriaWorkoutRouteStore.reconcile(from: newID,
                                                              to: newID,
                                                              activityType: .strength,
                                                              start: edited.startedAt,
                                                              end: edited.endedAt).get())
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: newID))
    }

    @MainActor
    func testFailedRouteReconciliationReportsFailureAndPreservesOriginalAssociation() throws {
        let oldID = "route-reconcile-source-\(UUID().uuidString)"
        let newID = "route-reconcile-blocked-\(UUID().uuidString)"
        let routesDirectory = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first!
            .appendingPathComponent("atria-workout-routes", isDirectory: true)
        let blockedDestination = routesDirectory.appendingPathComponent("\(newID).json",
                                                                         isDirectory: true)
        defer {
            _ = AtriaWorkoutRouteStore.delete(workoutID: oldID)
            _ = AtriaWorkoutRouteStore.delete(workoutID: newID)
        }

        let start = Date(timeIntervalSince1970: 30_000)
        let points = (0..<3).map { index in
            AtriaWorkoutRoute.Point(latitude: 28.61 + Double(index) * 0.0001,
                                    longitude: 77.20,
                                    altitude: 200,
                                    timestamp: start.addingTimeInterval(Double(index) * 30),
                                    horizontalAccuracy: 5,
                                    verticalAccuracy: 5,
                                    startsNewSegment: index == 0)
        }
        let draft = AtriaWorkoutRouteRecorder.Draft(activityType: .walking,
                                                    startedAt: start,
                                                    endedAt: start.addingTimeInterval(60),
                                                    coverageStartedAt: start,
                                                    points: points,
                                                    distanceMeters: 25,
                                                    elevationGainMeters: 0,
                                                    pausedDuration: 0)
        XCTAssertNotNil(AtriaWorkoutRouteStore.save(draft, workoutID: oldID))
        try FileManager.default.createDirectory(at: blockedDestination,
                                                withIntermediateDirectories: true)

        let result = AtriaWorkoutRouteStore.reconcile(from: oldID,
                                                      to: newID,
                                                      activityType: .walking,
                                                      start: start,
                                                      end: start.addingTimeInterval(60))

        guard case .failure(.writeFailed) = result else {
            return XCTFail("A blocked destination must report a route write failure")
        }
        XCTAssertNotNil(AtriaWorkoutRouteStore.load(workoutID: oldID),
                        "A failed route write must leave the original workout route intact")
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: newID))
    }

    @MainActor
    func testPendingEditCommitsForwardAfterMetadataWasDurable() throws {
        let oldID = "route-transaction-old-\(UUID().uuidString)"
        let newID = "route-transaction-new-\(UUID().uuidString)"
        _ = AtriaWorkoutRouteStore.clearPendingTransaction()
        defer {
            _ = AtriaWorkoutRouteStore.delete(workoutID: oldID)
            _ = AtriaWorkoutRouteStore.delete(workoutID: newID)
            _ = AtriaWorkoutRouteStore.clearPendingTransaction()
        }
        let start = Date(timeIntervalSince1970: 40_000)
        let points = (0..<5).map { index in
            AtriaWorkoutRoute.Point(latitude: 28.61 + Double(index) * 0.0001,
                                    longitude: 77.20,
                                    altitude: 200,
                                    timestamp: start.addingTimeInterval(Double(index) * 30),
                                    horizontalAccuracy: 5,
                                    verticalAccuracy: 5,
                                    startsNewSegment: index == 0)
        }
        let draft = AtriaWorkoutRouteRecorder.Draft(activityType: .walking,
                                                    startedAt: start,
                                                    endedAt: start.addingTimeInterval(120),
                                                    coverageStartedAt: start,
                                                    points: points,
                                                    distanceMeters: 44,
                                                    elevationGainMeters: 0,
                                                    pausedDuration: 0)
        XCTAssertNotNil(AtriaWorkoutRouteStore.save(draft, workoutID: oldID))
        let original = AtriaWorkoutRouteStore.CanonicalWorkoutState(
            id: oldID,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            start: start,
            end: start.addingTimeInterval(120)
        )
        let editedStart = start.addingTimeInterval(30)
        let editedEnd = start.addingTimeInterval(90)
        XCTAssertTrue(AtriaWorkoutRouteStore.beginEditTransaction(
            from: original,
            to: newID,
            activityType: .running,
            start: editedStart,
            end: editedEnd
        ))

        let recovery = AtriaWorkoutRouteStore.recoverPendingTransaction(canonicalWorkouts: [
            .init(id: newID,
                  activityType: AtriaWorkoutActivityType.running.rawValue,
                  start: editedStart,
                  end: editedEnd)
        ])

        XCTAssertEqual(recovery, .completed)
        XCTAssertFalse(AtriaWorkoutRouteStore.hasPendingTransaction)
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: oldID))
        let route = try XCTUnwrap(AtriaWorkoutRouteStore.load(workoutID: newID))
        XCTAssertEqual(route.activityType, AtriaWorkoutActivityType.running.rawValue)
        XCTAssertEqual(route.points.count, 3)
        XCTAssertEqual(route.startedAt, editedStart)
        XCTAssertEqual(route.endedAt, editedEnd)
    }

    @MainActor
    func testPendingEditRestoresOriginalRouteWhenMetadataRolledBackToDifferentID() throws {
        let oldID = "route-transaction-original-\(UUID().uuidString)"
        let requestedID = "route-transaction-requested-\(UUID().uuidString)"
        let rollbackID = "route-transaction-rollback-\(UUID().uuidString)"
        _ = AtriaWorkoutRouteStore.clearPendingTransaction()
        defer {
            for id in [oldID, requestedID, rollbackID] {
                _ = AtriaWorkoutRouteStore.delete(workoutID: id)
            }
            _ = AtriaWorkoutRouteStore.clearPendingTransaction()
        }
        let start = Date(timeIntervalSince1970: 50_000)
        let end = start.addingTimeInterval(120)
        let points = [
            AtriaWorkoutRoute.Point(latitude: 28.61, longitude: 77.20, altitude: 200,
                                    timestamp: start, horizontalAccuracy: 5,
                                    startsNewSegment: true),
            AtriaWorkoutRoute.Point(latitude: 28.62, longitude: 77.21, altitude: 201,
                                    timestamp: end, horizontalAccuracy: 5)
        ]
        let draft = AtriaWorkoutRouteRecorder.Draft(activityType: .walking,
                                                    startedAt: start,
                                                    endedAt: end,
                                                    coverageStartedAt: start,
                                                    points: points,
                                                    distanceMeters: 1_500,
                                                    elevationGainMeters: 1,
                                                    pausedDuration: 0)
        XCTAssertNotNil(AtriaWorkoutRouteStore.save(draft, workoutID: oldID))
        XCTAssertTrue(AtriaWorkoutRouteStore.beginEditTransaction(
            from: .init(id: oldID,
                        activityType: AtriaWorkoutActivityType.walking.rawValue,
                        start: start,
                        end: end),
            to: requestedID,
            activityType: .running,
            start: start.addingTimeInterval(30),
            end: end
        ))
        // Simulate a destination written before route reconciliation failed.
        XCTAssertNotNil(AtriaWorkoutRouteStore.save(draft, workoutID: requestedID))

        let recovery = AtriaWorkoutRouteStore.recoverPendingTransaction(canonicalWorkouts: [
            .init(id: rollbackID,
                  activityType: AtriaWorkoutActivityType.walking.rawValue,
                  start: start,
                  end: end)
        ])

        XCTAssertEqual(recovery, .completed)
        XCTAssertFalse(AtriaWorkoutRouteStore.hasPendingTransaction)
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: oldID))
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: requestedID))
        let restored = try XCTUnwrap(AtriaWorkoutRouteStore.load(workoutID: rollbackID))
        XCTAssertEqual(restored.workoutID, rollbackID)
        XCTAssertEqual(restored.points, points)
        XCTAssertEqual(restored.activityType, AtriaWorkoutActivityType.walking.rawValue)
    }

    @MainActor
    func testPendingDeleteFollowsCanonicalMetadataState() throws {
        let workoutID = "route-transaction-delete-\(UUID().uuidString)"
        _ = AtriaWorkoutRouteStore.clearPendingTransaction()
        defer {
            _ = AtriaWorkoutRouteStore.delete(workoutID: workoutID)
            _ = AtriaWorkoutRouteStore.clearPendingTransaction()
        }
        let start = Date(timeIntervalSince1970: 60_000)
        let end = start.addingTimeInterval(60)
        let draft = AtriaWorkoutRouteRecorder.Draft(
            activityType: .walking,
            startedAt: start,
            endedAt: end,
            coverageStartedAt: start,
            points: [
                .init(latitude: 28.61, longitude: 77.20, altitude: 200,
                      timestamp: start, horizontalAccuracy: 5, startsNewSegment: true),
                .init(latitude: 28.62, longitude: 77.21, altitude: 201,
                      timestamp: end, horizontalAccuracy: 5)
            ],
            distanceMeters: 1_500,
            elevationGainMeters: 1,
            pausedDuration: 0
        )
        XCTAssertNotNil(AtriaWorkoutRouteStore.save(draft, workoutID: workoutID))
        XCTAssertTrue(AtriaWorkoutRouteStore.beginDeleteTransaction(workoutID: workoutID))

        let preserved = AtriaWorkoutRouteStore.recoverPendingTransaction(canonicalWorkouts: [
            .init(id: workoutID,
                  activityType: AtriaWorkoutActivityType.walking.rawValue,
                  start: start,
                  end: end)
        ])
        XCTAssertEqual(preserved, .completed)
        XCTAssertNotNil(AtriaWorkoutRouteStore.load(workoutID: workoutID),
                        "A route must survive when canonical metadata deletion did not commit")

        XCTAssertTrue(AtriaWorkoutRouteStore.beginDeleteTransaction(workoutID: workoutID))
        let deleted = AtriaWorkoutRouteStore.recoverPendingTransaction(canonicalWorkouts: [])
        XCTAssertEqual(deleted, .completed)
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: workoutID),
                     "A durable metadata deletion must finish orphan-route cleanup")
        XCTAssertFalse(AtriaWorkoutRouteStore.hasPendingTransaction)
    }

    func testActivityEditorWrapsMetadataAndRouteMutationsInDurableIntent() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaActivityMonitor.swift"),
            encoding: .utf8
        )
        let saveStart = try XCTUnwrap(source.range(of: "private func saveAll()"))
        let deleteStart = try XCTUnwrap(source.range(of: "private func deleteWorkout()",
                                                     range: saveStart.upperBound..<source.endIndex))
        let routeCardStart = try XCTUnwrap(source.range(of: "private var routeCard:",
                                                        range: deleteStart.upperBound..<source.endIndex))
        let saveBody = String(source[saveStart.lowerBound..<deleteStart.lowerBound])
        let deleteBody = String(source[deleteStart.lowerBound..<routeCardStart.lowerBound])

        let beginEdit = try XCTUnwrap(saveBody.range(of: "beginEditTransaction"))
        let metadataEdit = try XCTUnwrap(saveBody.range(of: "store.editConfirmedWorkout"))
        let routeEdit = try XCTUnwrap(saveBody.range(of: "AtriaWorkoutRouteStore.reconcile"))
        XCTAssertLessThan(beginEdit.lowerBound, metadataEdit.lowerBound)
        XCTAssertLessThan(metadataEdit.lowerBound, routeEdit.lowerBound)
        XCTAssertTrue(saveBody.contains("AtriaWorkoutRouteStore.clearPendingTransaction()"))
        XCTAssertTrue(saveBody.contains("recoverPendingTransaction("),
                      "A failed route write must drive the durable rollback recovery path")

        let beginDelete = try XCTUnwrap(deleteBody.range(of: "beginDeleteTransaction"))
        let metadataDelete = try XCTUnwrap(deleteBody.range(of: "store.deleteConfirmedWorkout"))
        let routeDelete = try XCTUnwrap(deleteBody.range(of: "AtriaWorkoutRouteStore.delete"))
        XCTAssertLessThan(beginDelete.lowerBound, metadataDelete.lowerBound)
        XCTAssertLessThan(metadataDelete.lowerBound, routeDelete.lowerBound)
    }

    func testLegacyRouteWithoutPausedDurationStillDecodes() throws {
        let json = """
        {
          "id":"route","workoutID":"workout","activityType":"Running",
          "startedAt":1000,"endedAt":1600,"points":[],
          "distanceMeters":2000,"elevationGainMeters":0
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let route = try decoder.decode(AtriaWorkoutRoute.self, from: json)

        XCTAssertNil(route.pausedDuration)
        XCTAssertEqual(route.movingDuration, 600)
    }

    @MainActor
    func testRouteSaveAsyncReturnsAfterUtilityQueuePersistence() async throws {
        let workoutID = "route-async-\(UUID().uuidString)"
        defer { AtriaWorkoutRouteStore.delete(workoutID: workoutID) }
        let start = Date(timeIntervalSince1970: 20_000)
        let draft = AtriaWorkoutRouteRecorder.Draft(
            activityType: .running,
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            coverageStartedAt: start,
            points: [
                AtriaWorkoutRoute.Point(latitude: 28.61, longitude: 77.20, altitude: 200,
                                        timestamp: start, horizontalAccuracy: 5),
                AtriaWorkoutRoute.Point(latitude: 28.62, longitude: 77.21, altitude: 201,
                                        timestamp: start.addingTimeInterval(60), horizontalAccuracy: 5),
            ],
            distanceMeters: 1_500,
            elevationGainMeters: 1,
            pausedDuration: 0
        )

        let saved = await withCheckedContinuation { continuation in
            AtriaWorkoutRouteStore.saveAsync(draft, workoutID: workoutID) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(saved?.workoutID, workoutID)
        XCTAssertEqual(AtriaWorkoutRouteStore.load(workoutID: workoutID)?.points.count, 2)
    }

    @MainActor
    func testAwaitableRouteSavePersistsRecoveryDraftOffTheCallerPath() async throws {
        let workoutID = "route-async-recovery-\(UUID().uuidString)"
        defer { AtriaWorkoutRouteStore.delete(workoutID: workoutID) }
        let start = Date(timeIntervalSince1970: 21_000)
        let draft = AtriaWorkoutRouteRecorder.Draft(
            activityType: .walking,
            startedAt: start,
            endedAt: start.addingTimeInterval(90),
            coverageStartedAt: start.addingTimeInterval(5),
            points: [
                AtriaWorkoutRoute.Point(latitude: 28.61, longitude: 77.20, altitude: 200,
                                        timestamp: start.addingTimeInterval(5), horizontalAccuracy: 5,
                                        startsNewSegment: true),
                AtriaWorkoutRoute.Point(latitude: 28.62, longitude: 77.21, altitude: 201,
                                        timestamp: start.addingTimeInterval(90), horizontalAccuracy: 5),
            ],
            distanceMeters: 1_200,
            elevationGainMeters: 1,
            pausedDuration: 10
        )

        let saved = await AtriaWorkoutRouteStore.saveAsync(draft, workoutID: workoutID)

        XCTAssertEqual(saved?.workoutID, workoutID)
        XCTAssertEqual(saved?.coverageStartedAt, draft.coverageStartedAt)
        XCTAssertEqual(saved?.pausedDuration, 10)
        XCTAssertEqual(AtriaWorkoutRouteStore.load(workoutID: workoutID), saved)
    }

    func testRecoveredWorkoutRoutePersistenceNeverBlocksMainActor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("Atria/AtriaHomeView.swift"),
                              encoding: .utf8)
        let start = try XCTUnwrap(home.range(of: "private func finalizePendingWorkoutIntent("))
        let end = try XCTUnwrap(home.range(of: "private func schedulePendingWorkoutRecoveryRetries()",
                                           range: start.upperBound..<home.endIndex))
        let recovery = String(home[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(recovery.contains("await AtriaWorkoutRouteStore.saveAsync("))
        XCTAssertFalse(recovery.contains("AtriaWorkoutRouteStore.save("))
    }

    func testWorkoutEndUsesAsynchronousRoutePersistence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("Atria/AtriaHomeView.swift"),
                              encoding: .utf8)
        let start = try XCTUnwrap(home.range(of: "private func endWorkoutSession(startedAt:"))
        let end = try XCTUnwrap(home.range(of: "private func workoutShareSnapshot(",
                                           range: start.upperBound..<home.endIndex))
        let body = String(home[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("AtriaWorkoutRouteStore.saveAsync"))
        XCTAssertFalse(body.contains("AtriaWorkoutRouteStore.save("))
    }

    func testOnlyOutdoorRouteActivitiesRequestGps() {
        for type in [AtriaWorkoutActivityType.running, .walking, .hiking, .cycling] {
            XCTAssertTrue(type.supportsRouteRecording)
        }
        for type in [AtriaWorkoutActivityType.strength, .yoga, .swimming, .other] {
            XCTAssertFalse(type.supportsRouteRecording)
        }
    }

    func testLegacyWorkoutLabelsResolveToActivitySpecificIcons() {
        XCTAssertEqual(AtriaWorkoutActivityType.resolved(activityType: nil,
                                                         subtype: nil,
                                                         label: "Evening walk"), .walking)
        XCTAssertEqual(AtriaWorkoutActivityType.resolved(activityType: nil,
                                                         subtype: "Outdoor bike",
                                                         label: "Workout"), .cycling)
        XCTAssertEqual(AtriaWorkoutActivityType.resolved(activityType: "Strength",
                                                         subtype: "Boxing",
                                                         label: "Workout"), .strength)
        XCTAssertEqual(AtriaWorkoutActivityType.resolved(activityType: nil,
                                                         subtype: nil,
                                                         label: "Pool laps"), .swimming)
        XCTAssertEqual(AtriaWorkoutActivityType.resolved(activityType: nil,
                                                         subtype: nil,
                                                         label: "Basketball practice"), .basketball)
        XCTAssertEqual(AtriaWorkoutActivityType.resolved(activityType: nil,
                                                         subtype: "Badminton",
                                                         label: "Activity"), .badminton)
        XCTAssertNotEqual(AtriaWorkoutActivityType.basketball.icon,
                          AtriaWorkoutActivityType.running.icon)
        XCTAssertNotEqual(AtriaWorkoutActivityType.cricket.icon,
                          AtriaWorkoutActivityType.sport.icon)
    }
}
