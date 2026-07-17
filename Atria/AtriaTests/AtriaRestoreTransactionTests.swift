import XCTest
@testable import Atria

final class AtriaRestoreTransactionTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-restore-transaction-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
        suiteName = "com.adidshaft.atria.tests.restore.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        defaults = nil
        suiteName = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testCrashAfterEveryDestinationCompletesForwardOnNextLaunch() throws {
        let fileA = temporaryDirectory.appendingPathComponent("sessions.json")
        let fileB = temporaryDirectory.appendingPathComponent("daily-rollups.json")
        let marker = temporaryDirectory.appendingPathComponent("marker.json")
        let oldA = Data("old sessions".utf8)
        let oldB = Data("old rollups".utf8)
        let newA = Data("new sessions".utf8)
        let newB = Data("new rollups".utf8)
        try oldA.write(to: fileA)
        try oldB.write(to: fileB)

        let transaction = AtriaRestoreTransaction(destinations: [
            .defaults(key: "sleep", previous: nil, next: .data(Data("sleep".utf8))),
            .file(path: fileA.path, previous: oldA, next: newA),
            .defaults(key: "maxHR", previous: .integer(180), next: .integer(195)),
            .file(path: fileB.path, previous: oldB, next: newB),
            .defaults(key: "onboarded", previous: .boolean(false), next: .boolean(true))
        ])

        for killIndex in transaction.destinations.indices {
            try oldA.write(to: fileA, options: .atomic)
            try oldB.write(to: fileB, options: .atomic)
            defaults.removeObject(forKey: "sleep")
            defaults.set(180, forKey: "maxHR")
            defaults.set(false, forKey: "onboarded")
            try? FileManager.default.removeItem(at: marker)

            XCTAssertThrowsError(try AtriaRestoreTransactionCoordinator.commit(
                transaction,
                markerURL: marker,
                defaults: defaults,
                injection: .init(crashForwardAfterDestination: killIndex)
            )) { error in
                XCTAssertEqual(error as? AtriaRestoreTransactionError, .simulatedCrash(killIndex))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

            XCTAssertEqual(
                AtriaRestoreTransactionCoordinator.recoverIfNeeded(markerURL: marker,
                                                                   defaults: defaults),
                .completedForward
            )
            XCTAssertEqual(try Data(contentsOf: fileA), newA)
            XCTAssertEqual(try Data(contentsOf: fileB), newB)
            XCTAssertEqual(defaults.data(forKey: "sleep"), Data("sleep".utf8))
            XCTAssertEqual(defaults.integer(forKey: "maxHR"), 195)
            XCTAssertTrue(defaults.bool(forKey: "onboarded"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testOrdinaryFailureAfterEveryDestinationRollsBackEverything() throws {
        let file = temporaryDirectory.appendingPathComponent("sessions.json")
        let marker = temporaryDirectory.appendingPathComponent("marker.json")
        let oldFile = Data("old".utf8)
        let newFile = Data("new".utf8)
        try oldFile.write(to: file)
        let transaction = AtriaRestoreTransaction(destinations: [
            .defaults(key: "sleep", previous: nil, next: .data(Data("sleep".utf8))),
            .file(path: file.path, previous: oldFile, next: newFile),
            .defaults(key: "maxHR", previous: .integer(180), next: .integer(195))
        ])

        for failureIndex in transaction.destinations.indices {
            try oldFile.write(to: file, options: .atomic)
            defaults.removeObject(forKey: "sleep")
            defaults.set(180, forKey: "maxHR")
            try? FileManager.default.removeItem(at: marker)

            XCTAssertThrowsError(try AtriaRestoreTransactionCoordinator.commit(
                transaction,
                markerURL: marker,
                defaults: defaults,
                injection: .init(failForwardAfterDestination: failureIndex)
            ))
            XCTAssertEqual(try Data(contentsOf: file), oldFile)
            XCTAssertNil(defaults.data(forKey: "sleep"))
            XCTAssertEqual(defaults.integer(forKey: "maxHR"), 180)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testRollbackFailureRetainsMarkerAndLaunchFinishesRollback() throws {
        let file = temporaryDirectory.appendingPathComponent("sessions.json")
        let marker = temporaryDirectory.appendingPathComponent("marker.json")
        let old = Data("old".utf8)
        let new = Data("new".utf8)
        try old.write(to: file)
        let transaction = AtriaRestoreTransaction(destinations: [
            .file(path: file.path, previous: old, next: new),
            .defaults(key: "maxHR", previous: .integer(180), next: .integer(195))
        ])

        XCTAssertThrowsError(try AtriaRestoreTransactionCoordinator.commit(
            transaction,
            markerURL: marker,
            defaults: defaults,
            injection: .init(failForwardAfterDestination: 0,
                             failRollbackAtDestination: 0)
        )) { error in
            XCTAssertEqual(error as? AtriaRestoreTransactionError, .rollbackFailed(0))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        XCTAssertEqual(AtriaRestoreTransactionCoordinator.recoverIfNeeded(markerURL: marker,
                                                                          defaults: defaults),
                       .completedRollback)
        XCTAssertEqual(try Data(contentsOf: file), old)
        XCTAssertEqual(defaults.integer(forKey: "maxHR"), 180)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCorruptMarkerIsRetainedFailClosed() throws {
        let marker = temporaryDirectory.appendingPathComponent("marker.json")
        try Data("not-json".utf8).write(to: marker)

        XCTAssertEqual(AtriaRestoreTransactionCoordinator.recoverIfNeeded(markerURL: marker,
                                                                          defaults: defaults),
                       .retainedMarker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
