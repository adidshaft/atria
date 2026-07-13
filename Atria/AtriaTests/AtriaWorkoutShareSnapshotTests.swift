import XCTest
@testable import Atria

final class AtriaWorkoutShareSnapshotTests: XCTestCase {
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
        XCTAssertNil(snapshot.routeFileURL)
        XCTAssertTrue(snapshot.routePoints.isEmpty)
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

    func testPrimaryWorkoutShareDoesNotSilentlyAttachExactGPX() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("ShareLink(item: shareURL)"))
        XCTAssertTrue(source.contains("ShareLink(item: routeFileURL)"))
        XCTAssertFalse(source.contains("ShareLink(items: [shareURL] +"))
        XCTAssertTrue(source.contains("Share exact GPX route"))
        XCTAssertTrue(source.contains("Share portable workout recap without route"))
        XCTAssertTrue(source.contains("canvasPicker\n                            .padding(.vertical, 6)\n                            .glassEffect(.regular, in: RoundedRectangle"),
                      "The workout style rail is a static glass tray; its child controls own interaction")
        XCTAssertEqual(source.components(separatedBy: ".glassEffect(.regular.interactive(), in: RoundedRectangle").count - 1,
                       1,
                       "Only the remaining interactive picker rail should claim interactive glass")
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
