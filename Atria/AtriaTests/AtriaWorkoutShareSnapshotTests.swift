import XCTest
@testable import Atria

final class AtriaWorkoutShareSnapshotTests: XCTestCase {
    func testBothWorkoutShareBuildersUseSubtypeSpecificActivityIcons() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceRoot = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let activity = try String(contentsOf: sourceRoot
            .appendingPathComponent("AtriaActivityMonitor.swift"), encoding: .utf8)
        let home = try String(contentsOf: sourceRoot
            .appendingPathComponent("AtriaHomeView.swift"), encoding: .utf8)

        for source in [activity, home] {
            XCTAssertTrue(source.contains(
                "activitySystemImage: AtriaActivityDisplayIcon.icon("
            ))
            XCTAssertTrue(source.contains("subtype: workout.activitySubtype"))
            XCTAssertTrue(source.contains("label: workout.label"))
        }
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Sport",
                                                     subtype: "Basketball",
                                                     label: "Practice"),
                       AtriaWorkoutActivityType.basketball.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Cardio",
                                                     subtype: "Stair climber",
                                                     label: "Intervals"),
                       AtriaWorkoutActivityType.stairClimber.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "HIIT",
                                                     subtype: "Jump rope",
                                                     label: "Conditioning"),
                       AtriaWorkoutActivityType.jumpRope.icon)
    }

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

    func testRouteWorkoutShareMakesTheRouteHeroAndKeepsTheRingCompact() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct AtriaWorkoutShareCardView: View"))
        let end = try XCTUnwrap(source.range(of: "enum AtriaWorkoutShareRouteProjection",
                                             range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])

        let route = try XCTUnwrap(card.range(of: "routeTrace"))
        let ring = try XCTUnwrap(card.range(of: "workoutRing", range: route.upperBound..<card.endIndex))
        XCTAssertLessThan(route.lowerBound, ring.lowerBound,
                          "A route workout should lead with its path instead of a dominant strain ring")
        XCTAssertTrue(card.contains("format == .story ? 124 : 132"))
        XCTAssertTrue(card.contains("format == .story ? 148 : 118"))
        XCTAssertTrue(card.contains("Text(\"ATRIA\")"))
        XCTAssertTrue(card.contains(".fontWidth(.expanded)"))
        XCTAssertTrue(card.contains(".accessibilityLabel(\"Atria\")"))
    }

    func testApprovedFitnessBackgroundsUseTheFullCardPhotoPreviewPath() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)

        for asset in ["ShareDawnRidgeline", "ShareKineticTopo",
                      "ShareNeonCircuit", "ShareConcreteAscent"] {
            XCTAssertTrue(source.contains("return \"\(asset)\""))
        }
        XCTAssertTrue(source.contains("ForEach(AtriaSharePictureBackground.allCases)"))
        XCTAssertTrue(source.contains("guard let image = UIImage(named: background.assetName) else { return }"))
        XCTAssertTrue(source.contains("photoBackground = image"),
                      "Selecting an approved background must drive the entire share-card preview")
        XCTAssertTrue(source.contains("Image(uiImage: photoBackground)"))
        XCTAssertTrue(source.contains(".frame(width: format.renderSize.width, height: format.renderSize.height)"))
        XCTAssertTrue(source.contains(".scaledToFill()"))
    }

    func testUnvalidatedZeroStepsAreNotPublishedOnWorkoutShareCard() {
        XCTAssertNil(AtriaWorkoutSharePresentation.stepsText(
            count: 0,
            isEstimated: true,
            activity: .walking
        ))
        XCTAssertEqual(AtriaWorkoutSharePresentation.stepsText(
            count: 0,
            isEstimated: false,
            activity: .walking
        ), "0")
        XCTAssertNil(AtriaWorkoutSharePresentation.stepsText(
            count: 842,
            isEstimated: true,
            activity: .running
        ))
        XCTAssertNil(AtriaWorkoutSharePresentation.stepsText(
            count: 842,
            isEstimated: true,
            activity: .strength
        ))
    }

    func testCompletedWorkoutShareOmitsStaleOrMissingStepProvenance() {
        let end = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertNil(AtriaWorkoutSharePresentation.completedStepsText(
            count: 842,
            isEstimated: true,
            capturedAt: end.addingTimeInterval(-1),
            workoutEndedAt: end,
            activity: .walking
        ))
        XCTAssertEqual(AtriaWorkoutSharePresentation.completedStepsText(
            count: 842,
            isEstimated: false,
            capturedAt: end.addingTimeInterval(-1),
            workoutEndedAt: end,
            activity: .walking
        ), "842")
        XCTAssertNil(AtriaWorkoutSharePresentation.completedStepsText(
            count: 842,
            isEstimated: true,
            capturedAt: end.addingTimeInterval(
                -AtriaLiveWorkoutStepProjection.freshnessInterval - 1
            ),
            workoutEndedAt: end,
            activity: .walking
        ))
        XCTAssertNil(AtriaWorkoutSharePresentation.completedStepsText(
            count: 842,
            isEstimated: true,
            capturedAt: nil,
            workoutEndedAt: end,
            activity: .walking
        ))
    }

    func testCompletedWalkingWorkoutExplainsEveryUnavailableStrapStepState() {
        let end = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertEqual(
            AtriaWorkoutSharePresentation.completedStepsPresentation(
                count: 842,
                isEstimated: true,
                capturedAt: nil,
                workoutEndedAt: end,
                activity: .walking
            ),
            AtriaWorkoutSharePresentation.CompletedSteps(
                valueText: "--",
                detailText: "No verified strap motion for this workout",
                isAvailable: false
            )
        )
        XCTAssertEqual(
            AtriaWorkoutSharePresentation.completedStepsPresentation(
                count: 842,
                isEstimated: true,
                capturedAt: end.addingTimeInterval(
                    -AtriaLiveWorkoutStepProjection.freshnessInterval - 1
                ),
                workoutEndedAt: end,
                activity: .walking
            ),
            AtriaWorkoutSharePresentation.CompletedSteps(
                valueText: "--",
                detailText: "Strap motion was not verified at workout end",
                isAvailable: false
            )
        )
        XCTAssertEqual(
            AtriaWorkoutSharePresentation.completedStepsPresentation(
                count: nil,
                isEstimated: nil,
                capturedAt: end,
                workoutEndedAt: end,
                activity: .walking
            ),
            AtriaWorkoutSharePresentation.CompletedSteps(
                valueText: "--",
                detailText: "No verified strap step count for this workout",
                isAvailable: false
            )
        )
        XCTAssertEqual(
            AtriaWorkoutSharePresentation.completedStepsPresentation(
                count: 842,
                isEstimated: true,
                capturedAt: end,
                workoutEndedAt: end,
                activity: .walking
            ),
            AtriaWorkoutSharePresentation.CompletedSteps(
                valueText: "--",
                detailText: "No verified strap step count for this workout",
                isAvailable: false
            )
        )
        XCTAssertNil(
            AtriaWorkoutSharePresentation.completedStepsPresentation(
                count: nil,
                isEstimated: nil,
                capturedAt: nil,
                workoutEndedAt: end,
                activity: .strength
            ),
            "Steps are not a relevant workout stat for non-locomotion activities"
        )
    }

    func testRoutePreviewBoundsGeometryAndPreservesEndpointsAndBreaks() {
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let points: [AtriaWorkoutRoute.Point] = (0..<1_000).map { (index: Int) -> AtriaWorkoutRoute.Point in
            let latDrift: Double = Double(index) * 0.00001
            let lonDrift: Double = sin(Double(index) / 40) * 0.001
            return AtriaWorkoutRoute.Point(latitude: 28.6 + latDrift,
                                    longitude: 77.2 + lonDrift,
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

        XCTAssertTrue(source.contains("prepareShare(.image)"))
        XCTAssertTrue(source.contains("AtriaSystemShareSheet(url: payload.url)"))
        XCTAssertTrue(source.contains("ShareLink(item: routeFileURL)"))
        XCTAssertFalse(source.contains("UIActivityViewController(activityItems: [url, routeFileURL]"),
                       "The primary image share must not silently attach the precise GPX route")
        XCTAssertTrue(source.contains("Share exact GPX route"))
        XCTAssertTrue(source.contains("Share portable workout recap without route"))
        XCTAssertTrue(source.contains("private var controlDock: some View"))
        XCTAssertEqual(source.components(separatedBy:
            "canvasPicker\n            .padding(.vertical, 4)\n    }").count - 1,
                       1,
                       "The workout style rail should stay flat; its child controls own glass interaction")
        XCTAssertEqual(source.components(separatedBy: ".glassEffect(.regular.interactive(), in: RoundedRectangle").count - 1,
                       0,
                       "Share picker rails stay visually flat; only their individual actions should be interactive")
    }

    func testShareComposersUseOneNativeCircularGlassLayerOutsideToolbarContext() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)

        XCTAssertFalse(source.contains(".glassEffect(.regular.interactive(), in: Circle())"),
                       "The corner action label must not add a second glass circle")
        XCTAssertEqual(source.components(separatedBy: "AtriaGlassIconButtonStyle(tint: .white, size: 38)").count - 1,
                       6,
                       "Daily, workout, and weekly share should each keep one cancel and one action circular")
        XCTAssertEqual(source.components(separatedBy: ".frame(width: 18, height: 18)").count - 1,
                       6,
                       "All share icons and their preparing indicators should stay at native scale")

        let dailyStart = try XCTUnwrap(source.range(of: "struct AtriaShareSheet: View"))
        let rendererStart = try XCTUnwrap(source.range(of: "@MainActor\nenum AtriaShareCardRenderer",
                                                       range: dailyStart.upperBound..<source.endIndex))
        let composers = String(source[dailyStart.lowerBound..<rendererStart.lowerBound])
        XCTAssertFalse(composers.contains("ToolbarItem"),
                       "A toolbar-provided glass layer around a custom glass button recreates the nested control")
        XCTAssertEqual(composers.components(separatedBy: "GlassEffectContainer(spacing: 12)").count - 1, 3)
        XCTAssertTrue(composers.contains(".accessibilityLabel(\"Cancel\")"))
        XCTAssertTrue(composers.contains("shareCornerButton(systemImage: \"square.and.arrow.up\")"))
        XCTAssertFalse(composers.contains("saveShareCardToPhotos"),
                       "Weekly sharing should rely on the system share sheet instead of a second save action")
    }

    func testPhotoDataPreparationPropagatesStructuredCancellation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)
        let preparationStart = try XCTUnwrap(source.range(of: "enum AtriaSharePhotoPreparation"))
        let snapshotStart = try XCTUnwrap(source.range(of: "struct AtriaShareSnapshot:",
                                                       range: preparationStart.upperBound..<source.endIndex))
        let preparation = String(source[preparationStart.lowerBound..<snapshotStart.lowerBound])

        XCTAssertTrue(preparation.contains("let preparationTask = Task.detached"))
        XCTAssertTrue(preparation.contains("withTaskCancellationHandler"))
        XCTAssertTrue(preparation.contains("preparationTask.cancel()"),
                      "Cancelling the picker task must also cancel its detached image decode")
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
    func testPortablePhotoRecapReusesExactImageOnceAndRemainsUnique() async throws {
        let snapshot = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Cycling",
            duration: "52m",
            strain: "11.8",
            peakHeartRate: "171",
            zoneMinutes: []
        )
        let redData = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData {
            UIColor.systemRed.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
        let blueData = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData {
            UIColor.systemBlue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
        let redURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-portable-input-\(UUID().uuidString).png")
        let blueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-portable-input-\(UUID().uuidString).png")
        try redData.write(to: redURL)
        try blueData.write(to: blueURL)

        let redRecap = try await AtriaShareCardRenderer.renderPortableWorkoutURL(
            snapshot: snapshot,
            canvasStyle: .midnight,
            renderedImageURL: redURL,
            cacheResult: false,
            removeRenderedImageAfterEmbedding: true
        )
        let blueRecap = try await AtriaShareCardRenderer.renderPortableWorkoutURL(
            snapshot: snapshot,
            canvasStyle: .midnight,
            renderedImageURL: blueURL,
            cacheResult: false,
            removeRenderedImageAfterEmbedding: true
        )
        let redHTML = try String(contentsOf: redRecap, encoding: .utf8)
        let blueHTML = try String(contentsOf: blueRecap, encoding: .utf8)
        XCTAssertNotEqual(redRecap, blueRecap, "Photo recaps must be unique and uncached")
        XCTAssertTrue(redHTML.contains(redData.base64EncodedString()))
        XCTAssertTrue(blueHTML.contains(blueData.base64EncodedString()))
        XCTAssertFalse(redHTML.contains(blueData.base64EncodedString()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: redURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blueURL.path))
        await AtriaShareCardRenderer.releaseTemporaryExport(at: redRecap)
        await AtriaShareCardRenderer.releaseTemporaryExport(at: blueRecap)
    }

    @MainActor
    func testPortableCacheKeySeparatesRouteFilePresenceWithoutLeakingPath() {
        let base = AtriaWorkoutShareSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 900_000_000),
            activity: "Running",
            duration: "42m",
            strain: "12.4",
            peakHeartRate: "176",
            zoneMinutes: []
        )
        var routed = base
        routed.routeFileURL = URL(fileURLWithPath: "/private/precise-secret-route.gpx")

        let absent = AtriaShareCardRenderer.portableWorkoutCacheKey(snapshot: base, canvasStyle: .midnight)
        let present = AtriaShareCardRenderer.portableWorkoutCacheKey(snapshot: routed, canvasStyle: .midnight)
        XCTAssertNotEqual(absent, present)
        XCTAssertTrue(absent.contains("route-absent"))
        XCTAssertTrue(present.contains("route-present"))
        XCTAssertFalse(present.contains("precise-secret-route"))
    }

    func testLateCameraPreparationCannotReplaceANewerChoice() {
        XCTAssertFalse(AtriaSharePhotoPreparation.acceptsResult(
            generation: 4,
            currentGeneration: 5,
            requestedRenderKey: "old-camera",
            currentRenderKey: "new-photo"
        ))
        XCTAssertFalse(AtriaSharePhotoPreparation.acceptsResult(
            generation: 5,
            currentGeneration: 5,
            requestedRenderKey: "old-camera",
            currentRenderKey: "new-photo"
        ))
        XCTAssertTrue(AtriaSharePhotoPreparation.acceptsResult(
            generation: 5,
            currentGeneration: 5,
            requestedRenderKey: "current",
            currentRenderKey: "current"
        ))
    }

    @MainActor
    func testExportCleanupRemovesCompletedAndCancelledArtifacts() async throws {
        let completedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-completed-\(UUID().uuidString).tmp")
        try await AtriaShareCardRenderer.writeExportDataForTesting(Data("complete".utf8), to: completedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedURL.path))
        // CoreSimulator filesystems may omit NSFileProtectionKey even when the
        // production write requested complete protection. The source contract
        // below verifies that device-side protection is explicitly applied.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaShareCard.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".completeFileProtection"))
        XCTAssertTrue(source.contains("FileProtectionType.completeUnlessOpen"))
        await AtriaShareCardRenderer.releaseTemporaryExport(at: completedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedURL.path))

        let cancelledURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-cancelled-\(UUID().uuidString).tmp")
        let task = Task {
            await Task.yield()
            try await AtriaShareCardRenderer.writeExportDataForTesting(
                Data(repeating: 0x5a, count: 8 * 1_024 * 1_024),
                to: cancelledURL
            )
        }
        task.cancel()
        _ = try? await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledURL.path))
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

    @MainActor
    func testDailyAndWeeklyShareCacheKeysIncludeVisibleMetricContent() {
        let date = Date(timeIntervalSinceReferenceDate: 900_000_000)
        func ring(_ title: String, _ value: String) -> AtriaShareSnapshot.Ring {
            .init(title: title, value: value, detail: "measured", tintHex: "34c759", fill: 0.7)
        }
        let firstDaily = AtriaShareSnapshot(
            date: date,
            recovery: ring("Recovery", "71%"),
            sleep: ring("Sleep", "8h"),
            strain: ring("Strain", "9.2"),
            stats: [.init(id: "hrv", title: "HRV", value: "55 ms", detail: "overnight")]
        )
        let changedDaily = AtriaShareSnapshot(
            date: date,
            recovery: ring("Recovery", "42%"),
            sleep: ring("Sleep", "8h"),
            strain: ring("Strain", "9.2"),
            stats: [.init(id: "hrv", title: "HRV", value: "55 ms", detail: "overnight")]
        )
        let markerChangedDaily = AtriaShareSnapshot(
            date: date,
            recovery: ring("Recovery", "71%"),
            sleep: ring("Sleep", "8h"),
            strain: .init(title: "Strain",
                          value: "9.2",
                          detail: "measured",
                          tintHex: "34c759",
                          fill: 0.7,
                          stateTintHex: "ff4f7b",
                          targetFraction: 0.62),
            stats: [.init(id: "hrv", title: "HRV", value: "55 ms", detail: "overnight")]
        )
        XCTAssertNotEqual(
            AtriaShareCardRenderer.dailyCacheKey(snapshot: firstDaily,
                                                 format: .story,
                                                 selectedStatIDs: ["recovery", "strain", "sleep"],
                                                 canvasStyle: .midnight),
            AtriaShareCardRenderer.dailyCacheKey(snapshot: changedDaily,
                                                 format: .story,
                                                 selectedStatIDs: ["recovery", "strain", "sleep"],
                                                 canvasStyle: .midnight),
            "A second same-day share must not reuse an image with older visible metrics"
        )
        XCTAssertNotEqual(
            AtriaShareCardRenderer.dailyCacheKey(snapshot: firstDaily,
                                                 format: .story,
                                                 selectedStatIDs: ["recovery", "strain", "sleep"],
                                                 canvasStyle: .midnight),
            AtriaShareCardRenderer.dailyCacheKey(snapshot: markerChangedDaily,
                                                 format: .story,
                                                 selectedStatIDs: ["recovery", "strain", "sleep"],
                                                 canvasStyle: .midnight),
            "Target marker and configured state tint are visible share content"
        )

        let firstWeekly = AtriaWeeklyShareSnapshot(date: date,
                                                   title: "Weekly report",
                                                   recoveryAverage: "68%",
                                                   recoveryDelta: "+4%",
                                                   sleepConsistency: "Strong",
                                                   bestDay: "Tuesday",
                                                   hardestDay: "Friday",
                                                   note: nil)
        let changedWeekly = AtriaWeeklyShareSnapshot(date: date,
                                                     title: "Weekly report",
                                                     recoveryAverage: "74%",
                                                     recoveryDelta: "+4%",
                                                     sleepConsistency: "Strong",
                                                     bestDay: "Tuesday",
                                                     hardestDay: "Friday",
                                                     note: nil)
        XCTAssertNotEqual(
            AtriaShareCardRenderer.weeklyCacheKey(snapshot: firstWeekly,
                                                  format: .story,
                                                  canvasStyle: .midnight),
            AtriaShareCardRenderer.weeklyCacheKey(snapshot: changedWeekly,
                                                  format: .story,
                                                  canvasStyle: .midnight),
            "Weekly share caching must include every visible report value"
        )
    }
}
