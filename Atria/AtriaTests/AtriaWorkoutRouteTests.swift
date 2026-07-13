import XCTest
import CoreLocation
@testable import Atria

final class AtriaWorkoutRouteTests: XCTestCase {
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
        XCTAssertTrue(homeSource.contains("@State private var workoutRouteRecorder: AtriaWorkoutRouteRecorder"))
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
        var preview: [CLLocationCoordinate2D] = []
        for index in 0..<20_000 {
            preview = AtriaWorkoutRouteRecorder.previewCoordinates(
                byAppending: CLLocationCoordinate2D(latitude: Double(index),
                                                     longitude: -Double(index)),
                to: preview,
                limit: limit
            )
            XCTAssertLessThanOrEqual(preview.count, limit)
        }

        XCTAssertEqual(preview.first?.latitude, 0)
        XCTAssertEqual(preview.last?.latitude, 19_999)
        XCTAssertEqual(preview.last?.longitude, -19_999)
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
        XCTAssertTrue(routeSource.contains("snapshot.previewCoordinates = previewCoordinates"))
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

        AtriaWorkoutRouteStore.reconcile(from: oldID,
                                         to: newID,
                                         activityType: .running,
                                         start: start.addingTimeInterval(30),
                                         end: start.addingTimeInterval(90))
        let edited = try XCTUnwrap(AtriaWorkoutRouteStore.load(workoutID: newID))
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: oldID))
        XCTAssertEqual(edited.activityType, AtriaWorkoutActivityType.running.rawValue)
        XCTAssertEqual(edited.points.count, 3)
        XCTAssertTrue(edited.points[0].startsNewSegment ?? false)
        XCTAssertEqual(edited.startedAt, start.addingTimeInterval(30))
        XCTAssertEqual(edited.endedAt, start.addingTimeInterval(90))

        AtriaWorkoutRouteStore.reconcile(from: newID,
                                         to: newID,
                                         activityType: .strength,
                                         start: edited.startedAt,
                                         end: edited.endedAt)
        XCTAssertNil(AtriaWorkoutRouteStore.load(workoutID: newID))
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
