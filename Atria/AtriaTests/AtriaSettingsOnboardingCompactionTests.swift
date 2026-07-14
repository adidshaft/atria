import XCTest

final class AtriaSettingsOnboardingCompactionTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testSettingsRootIsFiveRowNavigationHubInsteadOfExpandableWall() throws {
        let source = try source("AtriaSettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "private var settingsHub"))
        let end = try XCTUnwrap(source.range(of: "private var personalSettingsPage",
                                              range: start.upperBound..<source.endIndex))
        let hub = String(source[start.lowerBound..<end.lowerBound])

        for title in ["Personal", "Strap", "Alerts", "Data", "Privacy & About"] {
            XCTAssertTrue(source.contains("\"\(title)\""))
        }
        XCTAssertTrue(hub.contains("ForEach(visibleDestinations)"))
        XCTAssertEqual(hub.components(separatedBy: "NavigationLink(value:").count - 1, 1,
                       "One reused link type prevents the on-device Swift metadata stack overflow")
        XCTAssertTrue(hub.contains("destination != .developer"),
                      "The sixth destination remains developer-only")
        XCTAssertTrue(source.contains(".navigationDestination(for: Destination.self)"),
                      "The first Settings frame must not construct every destination")
        XCTAssertFalse(hub.contains("DisclosureGroup"))
        XCTAssertFalse(source.contains("atria.settings.v3.expanded."))
        XCTAssertTrue(source.contains("Button(\"Close\") { dismiss() }"),
                      "Settings auto-save, so the dismissal action should say Close")
    }

    func testSettingsDestinationsPreserveEveryFunctionalSection() throws {
        let source = try source("AtriaSettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "private var personalSettingsPage"))
        let end = try XCTUnwrap(source.range(of: "/// Entry to the leaderboard demo",
                                              range: start.upperBound..<source.endIndex))
        let destinations = String(source[start.lowerBound..<end.lowerBound])

        for section in [
            "todayLayoutSection", "profileSection", "appearanceSection", "coachSettingsPage",
            "AtriaAdvancedTargetsSettingsView()",
            "radioModeSection", "heartRateBroadcastSection", "deviceSection",
            "sensorAvailabilitySection", "alertsSection", "dataSection",
            "AtriaResearchSharingSection", "leaderboardRow", "sparringRow", "aboutSection",
            "researchValidationSection"
        ] {
            XCTAssertTrue(destinations.contains(section), "Missing settings section: \(section)")
        }
        XCTAssertTrue(destinations.contains("compactSettingsForm(title:"))
        XCTAssertTrue(source.contains(".environment(\\.defaultMinListRowHeight, 44)"))
    }

    func testSettingsGearDefersAdvancedTargetDefaultsUntilDestinationOpens() throws {
        let source = try source("AtriaSettingsView.swift")
        let advancedStart = try XCTUnwrap(source.range(of: "private struct AtriaAdvancedTargetsSettingsView"))
        let settingsRoot = String(source[..<advancedStart.lowerBound])
        let advancedTargets = String(source[advancedStart.lowerBound...])

        XCTAssertFalse(settingsRoot.contains("@AtriaDefault(\"atria.target."),
                       "Opening Settings must not construct advanced target observers")
        XCTAssertFalse(settingsRoot.contains("@AtriaDefault(\"atria.sleep.baseNeedHours\""))
        XCTAssertTrue(settingsRoot.contains("NavigationLink {\n                    AtriaAdvancedTargetsSettingsView()"))
        XCTAssertFalse(settingsRoot.contains(".onChange(of: recoveryTargetSignature)"))

        XCTAssertTrue(advancedTargets.contains("@AtriaDefault(\"atria.target.recovery.greenLower\""))
        XCTAssertTrue(advancedTargets.contains("@AtriaDefault(\"atria.target.vo2.redDelta\""))
        XCTAssertTrue(advancedTargets.contains("@AtriaDefault(\"atria.sleep.baseNeedHours\""))
        XCTAssertTrue(advancedTargets.contains(".onChange(of: recoveryTargetSignature)"))
        XCTAssertTrue(advancedTargets.contains("private var targetsSection: some View"))
    }

    func testSettingsGearDefersArchiveFootprintWalkUntilDataDestinationOpens() throws {
        let source = try source("AtriaSettingsView.swift")
        let bodyStart = try XCTUnwrap(source.range(of: "var body: some View"))
        let hubStart = try XCTUnwrap(source.range(of: "// MARK: Settings hub",
                                                  range: bodyStart.upperBound..<source.endIndex))
        let rootBody = String(source[bodyStart.lowerBound..<hubStart.lowerBound])

        XCTAssertFalse(rootBody.contains("refreshStorageFootprint"),
                       "Opening the Settings sheet must not enumerate the historical archive")

        let dataStart = try XCTUnwrap(source.range(of: "private var dataSettingsPage"))
        let privacyStart = try XCTUnwrap(source.range(of: "private var privacySettingsPage",
                                                       range: dataStart.upperBound..<source.endIndex))
        let dataPage = String(source[dataStart.lowerBound..<privacyStart.lowerBound])
        XCTAssertTrue(dataPage.contains(".task { await refreshDataDestinationStatusIfNeeded() }"),
                      "Backup and storage probes should start only after Data is visible")
        XCTAssertTrue(source.contains("guard storageFootprintTotal == nil else { return }"),
                      "Re-entering Data must reuse the footprint already computed for this presentation")
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"),
                      "Filesystem enumeration must remain off the main actor")
    }

    func testSettingsFirstFrameDoesNotHydrateDataOrMutateDeveloperDefaults() throws {
        let source = try source("AtriaSettingsView.swift")
        let bodyStart = try XCTUnwrap(source.range(of: "var body: some View"))
        let hubStart = try XCTUnwrap(source.range(of: "// MARK: Settings hub",
                                                  range: bodyStart.upperBound..<source.endIndex))
        let rootBody = String(source[bodyStart.lowerBound..<hubStart.lowerBound])

        XCTAssertFalse(rootBody.contains("backupStatusProvider()"),
                       "Presenting the gear must not run backup providers")
        XCTAssertTrue(source.contains("private func refreshDataDestinationStatusIfNeeded() async"))
        XCTAssertTrue(source.contains("backupStatus = backupStatusProvider()"))
        XCTAssertFalse(source.contains("researchValidationContent != nil && AtriaDeveloperMode.isEnabled"),
                       "The first Settings body must not run a UserDefaults-mutating developer-mode check")
        XCTAssertFalse(source.contains("makeResearchValidationContent = researchValidationContent,\n           AtriaDeveloperMode.isEnabled"))
    }

    func testSettingsPresentationIsIsolatedFromHomeRootInvalidation() throws {
        let home = try source("AtriaHomeView.swift")

        XCTAssertTrue(home.contains("private final class AtriaSettingsPresentationCoordinator: ObservableObject"))
        XCTAssertTrue(home.contains("private struct AtriaSettingsPresentationHost<Content: View>: View, Equatable"))
        XCTAssertTrue(home.contains("private struct AtriaSettingsPresentationRevision: Equatable"))
        XCTAssertTrue(home.contains("@State private var settingsPresentation = AtriaSettingsPresentationCoordinator()"))
        XCTAssertTrue(home.contains("AtriaSettingsPresentationHost(coordinator: settingsPresentation,"))
        XCTAssertTrue(home.contains("revision: settingsPresentationRevision"))
        XCTAssertTrue(home.contains(".equatable()"),
                      "Live pulse and step updates must not rebuild the presented Settings graph")
        XCTAssertTrue(home.contains("settingsPresentation.isPresented = true"))
        XCTAssertFalse(home.contains("@State private var showSettings"),
                       "The gear must not invalidate and rebuild the complete Home hierarchy")
        XCTAssertFalse(home.contains(".sheet(isPresented: $showSettings)"))
    }

    func testDeveloperValidationGraphIsBuiltOnlyAfterDeveloperDestinationOpens() throws {
        let settings = try source("AtriaSettingsView.swift")
        let home = try source("AtriaHomeView.swift")

        XCTAssertTrue(settings.contains("let researchValidationContent: (() -> AnyView)?"))
        XCTAssertTrue(settings.contains("makeResearchValidationContent()"))
        XCTAssertTrue(home.contains("researchValidationContent: developerModeEnabled ? {"))
        XCTAssertFalse(home.contains("researchValidationContent: developerModeEnabled ? AnyView("),
                       "The Settings gear must not eagerly construct developer validation")
    }

    func testCoachConfigurationLivesInSettingsInsteadOfDailyCard() throws {
        let settings = try source("AtriaSettingsView.swift")
        let card = try source("AtriaAICoachCard.swift")

        XCTAssertTrue(settings.contains("private var coachSettingsPage: some View"))
        XCTAssertTrue(settings.contains("Picker(\"Mode\", selection: coachModeBinding)"))
        XCTAssertTrue(settings.contains("Picker(\"Service\", selection: coachProviderBinding)"))
        XCTAssertTrue(settings.contains("onSaveAICoachAPIKey(key)"))
        XCTAssertTrue(settings.contains("onDeleteAICoachAPIKey()"))

        XCTAssertFalse(card.contains("SecureField"))
        XCTAssertFalse(card.contains("Picker(\"Provider\""))
        XCTAssertFalse(card.contains("Save key"))
        XCTAssertTrue(card.contains("Label(\"Sources\", systemImage: \"checkmark.shield\")"))
    }

    func testSettingsHidesLongBackupPathWithoutDroppingAccessibleLocation() throws {
        let source = try source("AtriaSettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "private var backupSummaryText"))
        let end = try XCTUnwrap(source.range(of: "private var backupPathAccessibilityHint",
                                              range: start.upperBound..<source.endIndex))
        let summary = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(summary.contains("backupStatus.path"),
                       "Filesystem paths should not consume the visible summary row")
        XCTAssertTrue(source.contains("private var backupPathAccessibilityHint"))
        XCTAssertTrue(source.contains(".accessibilityHint(backupPathAccessibilityHint)"))
    }

    func testActiveOnboardingUsesCompactVisualHierarchyAndShortConsentCopy() throws {
        let flow = try source("AtriaOnboardingFlow.swift")
        let content = try source("ContentView.swift")
        let start = try XCTUnwrap(content.range(of: "struct AtriaOnboardingSharingChoiceStep"))
        let end = try XCTUnwrap(content.range(of: "private enum OfficialAppCoexistenceRisk",
                                               range: start.upperBound..<content.endIndex))
        let sharing = String(content[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(flow.contains(".frame(maxWidth: 260)"))
        XCTAssertTrue(flow.contains(".font(.system(size: 28, weight: .bold, design: .rounded))"))
        XCTAssertTrue(flow.contains(".frame(maxWidth: .infinity, minHeight: 58)"))
        XCTAssertTrue(sharing.contains("Anonymous data only. No identity or location. Review the bundle before sharing."))
        XCTAssertFalse(sharing.contains("Share anonymized heart-rate, sleep and workout series"))
        XCTAssertTrue(sharing.contains("DisclosureGroup(\"Privacy details\")"),
                      "Detailed consent information remains available on demand")
        XCTAssertTrue(sharing.contains(".accessibilityHint("),
                      "Compact visible copy must retain fuller VoiceOver context")
    }

    func testResearchSettingsFooterIsCompactButConsentContextRemainsAccessible() throws {
        let source = try source("AtriaResearchBundle.swift")
        let start = try XCTUnwrap(source.range(of: "struct AtriaResearchSharingSection"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaResearchShareSheetHost",
                                              range: start.upperBound..<source.endIndex))
        let section = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(section.contains("Text(researchSharingFooter)"))
        XCTAssertTrue(section.contains("Optional · date-scrambled · inspect before sharing."))
        XCTAssertTrue(section.contains(".accessibilityHint(researchSharingAccessibilityHint)"))
        XCTAssertFalse(section.contains("Sharing is a gift:"))
    }
}
