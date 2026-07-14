import XCTest
@testable import Atria

final class AtriaWorkoutShareSnapshotTests: XCTestCase {
    func testUnavailableMetricsAreOmittedFromSocialPresentation() {
        for unavailable in [nil, "", "  ", "--", "Learning", "Building",
                            "Incomplete", "Unknown", "Unavailable"] as [String?] {
            XCTAssertFalse(AtriaWorkoutSharePresentation.metricIsAvailable(unavailable))
        }
        XCTAssertTrue(AtriaWorkoutSharePresentation.metricIsAvailable("0"))
        XCTAssertTrue(AtriaWorkoutSharePresentation.metricIsAvailable("0.0"))
        XCTAssertTrue(AtriaWorkoutSharePresentation.metricIsAvailable("42m"))
        XCTAssertTrue(AtriaWorkoutSharePresentation.metricIsAvailable("5:07/km"))
    }

    func testUnknownAndZeroStrainDoNotInventVisibleShareProgress() {
        XCTAssertNil(AtriaWorkoutSharePresentation.strainFraction("--"))
        XCTAssertNil(AtriaWorkoutSharePresentation.strainFraction("Learning"))
        XCTAssertEqual(AtriaWorkoutSharePresentation.strainFraction("0.0"), 0)
        XCTAssertEqual(AtriaWorkoutSharePresentation.strainFraction("10.5"), 0.5)
        XCTAssertEqual(AtriaWorkoutSharePresentation.strainFraction("99"), 1)
    }

    func testZoneShareSegmentsReflectRecordedMinutesAndOmitZeroZones() {
        let zones = [
            AtriaWorkoutShareSnapshot.ZoneMinute(id: 1, label: "Z1", minutes: 0, tintHex: "#1"),
            AtriaWorkoutShareSnapshot.ZoneMinute(id: 2, label: "Z2", minutes: 10, tintHex: "#2"),
            AtriaWorkoutShareSnapshot.ZoneMinute(id: 3, label: "Z3", minutes: 30, tintHex: "#3")
        ]

        let fractions = AtriaWorkoutSharePresentation.zoneFractions(zones)

        XCTAssertNil(fractions[1])
        XCTAssertEqual(fractions[2], 0.25)
        XCTAssertEqual(fractions[3], 0.75)
        XCTAssertEqual(fractions.values.reduce(0, +), 1, accuracy: 0.000_001)
    }

    func testStoryComposerFitsTheWholeNineBySixteenCanvas() {
        let portrait = AtriaShareComposerLayout.fittedStorySize(
            in: CGSize(width: 390, height: 600)
        )
        XCTAssertEqual(portrait.width / portrait.height, 9.0 / 16.0, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(portrait.width, 390)
        XCTAssertLessThanOrEqual(portrait.height, 600)

        let landscape = AtriaShareComposerLayout.fittedStorySize(
            in: CGSize(width: 700, height: 320)
        )
        XCTAssertEqual(landscape.width / landscape.height, 9.0 / 16.0, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(landscape.width, 700)
        XCTAssertLessThanOrEqual(landscape.height, 320)
    }

    func testWorkoutShareNeverLabelsUnknownZonesAsLearning() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct AtriaWorkoutShareCardView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaWorkoutShareRouteShape",
                                             range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(card.contains("if snapshot.zoneMinutes.contains(where: { $0.minutes > 0 })"))
        XCTAssertFalse(card.localizedCaseInsensitiveContains("learning"),
                       "Unknown zone data should be omitted from a social card, not shown as a placeholder")
        XCTAssertTrue(card.contains("candidates.filter { AtriaWorkoutSharePresentation.metricIsAvailable($0.value) }"),
                      "Unavailable workout stats should be removed rather than exported as placeholders")
        XCTAssertTrue(card.contains("if strainFill != nil"),
                      "An unavailable strain must not be printed in the center of the share card")
    }

    func testOutdoorWorkoutShareCarriesRouteAndActivityIdentity() {
        let routeURL = FileManager.default.temporaryDirectory.appendingPathComponent("run.gpx")
        let snapshot = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Running",
            duration: "42m",
            strain: "12.4",
            peakHeartRate: "176",
            zoneMinutes: [],
            averageHeartRate: "151",
            distance: "8.20 km",
            pace: "5:07/km",
            activitySystemImage: AtriaWorkoutActivityType.running.icon,
            routeFileURL: routeURL,
            routePoints: [
                .init(latitude: 28.6139, longitude: 77.2090, startsNewSegment: true),
                .init(latitude: 28.6148, longitude: 77.2104, startsNewSegment: false)
            ]
        )

        XCTAssertEqual(snapshot.distance, "8.20 km")
        XCTAssertEqual(snapshot.pace, "5:07/km")
        XCTAssertEqual(snapshot.activitySystemImage, "figure.run")
        XCTAssertEqual(snapshot.routeFileURL, routeURL)
        XCTAssertEqual(snapshot.routePoints.count, 2)
    }

    func testIndoorWorkoutShareDefaultsRemainPortableWithoutRoute() {
        let snapshot = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Strength",
            duration: "55m",
            strain: "10.2",
            peakHeartRate: "164",
            zoneMinutes: []
        )

        XCTAssertNil(snapshot.distance)
        XCTAssertNil(snapshot.pace)
        XCTAssertNil(snapshot.steps)
        XCTAssertNil(snapshot.routeFileURL)
        XCTAssertTrue(snapshot.routePoints.isEmpty)
    }

    @MainActor
    func testWorkoutStepsAreOptionalAndParticipateInShareIdentity() {
        let base = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Walking",
            duration: "24m",
            strain: "5.2",
            peakHeartRate: "132",
            zoneMinutes: []
        )
        var stepped = base
        stepped.steps = "2,184"

        XCTAssertNil(base.steps)
        XCTAssertEqual(stepped.steps, "2,184")
        XCTAssertNotEqual(base, stepped)
        XCTAssertNotEqual(
            AtriaShareCardRenderer.workoutCacheKey(snapshot: base,
                                                   format: .story,
                                                   canvasStyle: .midnight),
            AtriaShareCardRenderer.workoutCacheKey(snapshot: stepped,
                                                   format: .story,
                                                   canvasStyle: .midnight)
        )
    }

    func testWorkoutShareCardUsesStepsOnlyWhenEvidenceExists() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct AtriaWorkoutShareCardView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaWorkoutShareRouteShape",
                                             range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(card.contains("if let steps = snapshot.steps"))
        XCTAssertTrue(card.contains("WorkoutStat(title: \"Steps\", value: steps)"))
    }

    func testRoutePreviewBoundsGeometryAndPreservesEndpointsAndBreaks() {
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let points = (0..<1_000).map { index in
            AtriaWorkoutRoute.Point(latitude: 28.6 + Double(index) * 0.00001,
                                    longitude: 77.2 + sin(Double(index) / 40) * 0.001,
                                    altitude: 200,
                                    timestamp: start.addingTimeInterval(Double(index)),
                                    horizontalAccuracy: 3,
                                    startsNewSegment: index == 500)
        }
        let route = AtriaWorkoutRoute(id: "bounded-share-route",
                                      workoutID: "bounded-share-route",
                                      activityType: "Running",
                                      startedAt: start,
                                      endedAt: start.addingTimeInterval(999),
                                      points: points,
                                      distanceMeters: 4_200,
                                      elevationGainMeters: 0)

        let preview = AtriaWorkoutShareSnapshot.routePreviewPoints(from: route, limit: 80)

        XCTAssertLessThanOrEqual(preview.count, 80)
        XCTAssertEqual(preview.first?.latitude, points.first?.latitude)
        XCTAssertEqual(preview.last?.latitude, points.last?.latitude)
        XCTAssertTrue(preview.contains(where: { $0.startsNewSegment && $0.latitude == points[500].latitude }))
    }

    func testWorkoutShareRouteProjectionKeepsEndpointsInsideStoryTrace() {
        let points = [
            AtriaWorkoutShareSnapshot.RoutePoint(latitude: 28.6139,
                                                 longitude: 77.2090,
                                                 startsNewSegment: true),
            AtriaWorkoutShareSnapshot.RoutePoint(latitude: 28.6148,
                                                 longitude: 77.2110,
                                                 startsNewSegment: false),
            AtriaWorkoutShareSnapshot.RoutePoint(latitude: 28.6160,
                                                 longitude: 77.2102,
                                                 startsNewSegment: false)
        ]
        let rect = CGRect(x: 0, y: 0, width: 280, height: 80)

        let projected = AtriaWorkoutShareRouteProjection.projectedPoints(points, in: rect)

        XCTAssertEqual(projected.count, points.count)
        XCTAssertTrue(projected.allSatisfy { rect.contains($0) })
        XCTAssertNotEqual(projected.first, projected.last)
    }

    func testWorkoutShareRouteTraceMarksStartAndFinish() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct AtriaWorkoutShareRouteTrace"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaWorkoutShareRouteShape",
                                             range: start.upperBound..<source.endIndex))
        let trace = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(trace.contains("routeEndpoint(at: start, tint: .green)"))
        XCTAssertTrue(trace.contains("routeEndpoint(at: finish, tint: .red)"))
        XCTAssertTrue(trace.contains(".overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.5))"))
    }

    func testPrimaryWorkoutShareDoesNotSilentlyAttachExactGPX() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("ShareLink(item: shareURL)"))
        XCTAssertTrue(source.contains("ShareLink(item: routeFileURL)"))
        XCTAssertFalse(source.contains("ShareLink(items: [shareURL] +"))
        XCTAssertTrue(source.contains("Share exact GPX route"))
        XCTAssertTrue(source.contains("Share portable workout recap without route"))
        XCTAssertTrue(source.contains("private var controlDock: some View"))
        XCTAssertTrue(source.contains("canvasPicker\n            .padding(.vertical, 4)\n            .glassEffect(.regular, in: RoundedRectangle"),
                      "The workout style rail is a static glass tray below the preview; its child controls own interaction")
        XCTAssertEqual(source.components(separatedBy: ".glassEffect(.regular.interactive(), in: RoundedRectangle").count - 1,
                       1,
                       "Only the remaining interactive picker rail should claim interactive glass")
    }

    func testShareComposersUseOneNativeCircularGlassLayerOutsideToolbarContext() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)

        XCTAssertFalse(source.contains(".glassEffect(.regular.interactive(), in: Circle())"),
                       "The corner action label must not add a second glass circle")
        XCTAssertEqual(source.components(separatedBy: "AtriaGlassIconButtonStyle(tint: .white, size: 38)").count - 1,
                       6,
                       "Daily and workout share should each keep cancel, live share, and disabled share circular")
        XCTAssertEqual(source.components(separatedBy: ".frame(width: 18, height: 18)").count - 1,
                       2,
                       "Both share labels should stay at native icon scale instead of becoming oversized controls")

        let dailyStart = try XCTUnwrap(source.range(of: "struct AtriaShareSheet: View"))
        let workoutStart = try XCTUnwrap(source.range(of: "struct AtriaWorkoutShareSheet: View",
                                                      range: dailyStart.upperBound..<source.endIndex))
        let cameraStart = try XCTUnwrap(source.range(of: "private struct AtriaShareCameraPicker",
                                                     range: workoutStart.upperBound..<source.endIndex))
        let composers = String(source[dailyStart.lowerBound..<cameraStart.lowerBound])
        XCTAssertFalse(composers.contains("ToolbarItem"),
                       "A toolbar-provided glass layer around a custom glass button recreates the nested control")
        XCTAssertEqual(composers.components(separatedBy: "GlassEffectContainer(spacing: 12)").count - 1, 2)
    }

    @MainActor
    func testWorkoutPhotoBackgroundRendersAFullMetadataFreeStory() throws {
        let snapshot = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Cycling",
            duration: "52m",
            strain: "11.8",
            peakHeartRate: "171",
            zoneMinutes: []
        )
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
        }

        let data = try AtriaShareCardRenderer.renderPNGData(snapshot: snapshot,
                                                            format: .story,
                                                            canvasStyle: .midnight,
                                                            photoBackground: photo)
        XCTAssertEqual(AtriaShareCardRenderer.pngPixelSize(data), AtriaShareFormat.story.pixelSize)
        XCTAssertFalse(AtriaShareCardRenderer.containsEXIFOrGPS(data))
    }

    @MainActor
    func testPortableRecapIsSelfContainedAndExcludesPreciseRoute() throws {
        let exactRoute = URL(fileURLWithPath: "/private/precise-home-route.gpx")
        let snapshot = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Run <Tempo>",
            duration: "42m",
            strain: "12.4",
            peakHeartRate: "176",
            zoneMinutes: [.init(id: 3, label: "Zone & 3", minutes: 12, tintHex: "ff9500")],
            averageHeartRate: "151",
            distance: "8.20 km",
            pace: "5:07/km",
            routeFileURL: exactRoute
        )

        let html = AtriaShareCardRenderer.portableWorkoutHTML(
            snapshot: snapshot,
            imageData: Data([0x89, 0x50, 0x4e, 0x47])
        )

        XCTAssertTrue(html.contains("data:image/png;base64,iVBORw=="))
        XCTAssertTrue(html.contains("Run &lt;Tempo&gt;"))
        XCTAssertTrue(html.contains("Zone &amp; 3"))
        XCTAssertTrue(html.contains("Precise route omitted for privacy."))
        XCTAssertFalse(html.contains(exactRoute.path))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("latitude"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("longitude"))
    }

    @MainActor
    func testSameDayWorkoutCardsDoNotReuseStaleMetrics() {
        let first = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Running",
            duration: "20m",
            strain: "6.1",
            peakHeartRate: "150",
            zoneMinutes: []
        )
        let second = AtriaWorkoutShareSnapshot(
            date: first.date,
            activity: first.activity,
            duration: "48m",
            strain: "12.7",
            peakHeartRate: "181",
            zoneMinutes: []
        )

        XCTAssertNotEqual(
            AtriaShareCardRenderer.workoutCacheKey(snapshot: first,
                                                   format: .story,
                                                   canvasStyle: .midnight),
            AtriaShareCardRenderer.workoutCacheKey(snapshot: second,
                                                   format: .story,
                                                   canvasStyle: .midnight)
        )
    }

    @MainActor
    func testRouteGeometryChangesCacheAndRendersMetadataFreeStory() throws {
        let base = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Running",
            duration: "42m",
            strain: "12.4",
            peakHeartRate: "176",
            zoneMinutes: [.init(id: 3, label: "Z3", minutes: 18, tintHex: "ff9500")],
            averageHeartRate: "151",
            distance: "8.20 km",
            pace: "5:07/km",
            activitySystemImage: AtriaWorkoutActivityType.running.icon
        )
        var routed = base
        routed.routePoints = [
            .init(latitude: 28.6139, longitude: 77.2090, startsNewSegment: true),
            .init(latitude: 28.6148, longitude: 77.2110, startsNewSegment: false),
            .init(latitude: 28.6160, longitude: 77.2102, startsNewSegment: false)
        ]

        XCTAssertNotEqual(
            AtriaShareCardRenderer.workoutCacheKey(snapshot: base, format: .story, canvasStyle: .midnight),
            AtriaShareCardRenderer.workoutCacheKey(snapshot: routed, format: .story, canvasStyle: .midnight)
        )
        let data = try AtriaShareCardRenderer.renderPNGData(snapshot: routed,
                                                            format: .story,
                                                            canvasStyle: .midnight)
        XCTAssertEqual(AtriaShareCardRenderer.pngPixelSize(data), AtriaShareFormat.story.pixelSize)
        XCTAssertFalse(AtriaShareCardRenderer.containsEXIFOrGPS(data))
    }
}
