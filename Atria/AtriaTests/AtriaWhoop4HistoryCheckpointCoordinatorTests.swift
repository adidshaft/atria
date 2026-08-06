import XCTest
@testable import Atria

final class AtriaWhoop4HistoryCheckpointCoordinatorTests: XCTestCase {
    func testCheckpointOnlyFollowsBoundedSuccessfulArchivePrefix() {
        let coordinator = AtriaWhoop4HistoryCheckpointCoordinator(threshold: 3)
        coordinator.begin(generation: 9)

        XCTAssertNil(coordinator.recordPersistence(generation: 9,
                                                    ordinal: 0,
                                                    succeeded: true))
        XCTAssertNil(coordinator.recordPersistence(generation: 9,
                                                    ordinal: 1,
                                                    succeeded: true))
        XCTAssertEqual(coordinator.recordPersistence(generation: 9,
                                                      ordinal: 2,
                                                      succeeded: true),
                       .init(generation: 9, throughOrdinal: 2))

        // A serial archive queue may finish later appends while the fsync is
        // running. They must remain in the next batch, not schedule a second
        // concurrent durability receipt.
        XCTAssertNil(coordinator.recordPersistence(generation: 9,
                                                    ordinal: 3,
                                                    succeeded: true))
        coordinator.checkpointCompleted(generation: 9, succeeded: true)

        XCTAssertNil(coordinator.recordPersistence(generation: 9,
                                                    ordinal: 4,
                                                    succeeded: true))
        XCTAssertNil(coordinator.recordPersistence(generation: 9,
                                                    ordinal: 5,
                                                    succeeded: true))
        XCTAssertEqual(coordinator.recordPersistence(generation: 9,
                                                      ordinal: 6,
                                                      succeeded: true),
                       .init(generation: 9, throughOrdinal: 6))
    }

    func testPersistenceOrCheckpointFailureSuppressesFurtherCheckpoints() {
        let coordinator = AtriaWhoop4HistoryCheckpointCoordinator(threshold: 2)
        coordinator.begin(generation: 4)

        XCTAssertNil(coordinator.recordPersistence(generation: 4,
                                                    ordinal: 0,
                                                    succeeded: false))
        XCTAssertNil(coordinator.recordPersistence(generation: 4,
                                                    ordinal: 1,
                                                    succeeded: true))
        XCTAssertNil(coordinator.recordPersistence(generation: 4,
                                                    ordinal: 2,
                                                    succeeded: true))

        coordinator.begin(generation: 5)
        XCTAssertNil(coordinator.recordPersistence(generation: 5,
                                                    ordinal: 0,
                                                    succeeded: true))
        XCTAssertEqual(coordinator.recordPersistence(generation: 5,
                                                      ordinal: 1,
                                                      succeeded: true),
                       .init(generation: 5, throughOrdinal: 1))
        coordinator.checkpointCompleted(generation: 5, succeeded: false)
        XCTAssertNil(coordinator.recordPersistence(generation: 5,
                                                    ordinal: 2,
                                                    succeeded: true))
    }

    func testStaleGenerationCannotScheduleOrMutateCurrentCheckpoint() {
        let coordinator = AtriaWhoop4HistoryCheckpointCoordinator(threshold: 1)
        coordinator.begin(generation: 7)

        XCTAssertNil(coordinator.recordPersistence(generation: 6,
                                                    ordinal: 10,
                                                    succeeded: true))
        XCTAssertEqual(coordinator.recordPersistence(generation: 7,
                                                      ordinal: 0,
                                                      succeeded: true),
                       .init(generation: 7, throughOrdinal: 0))
        coordinator.checkpointCompleted(generation: 6, succeeded: true)
        XCTAssertNil(coordinator.recordPersistence(generation: 7,
                                                    ordinal: 1,
                                                    succeeded: true))
    }

    func testFIFOBufferPreservesOrderWithoutRepeatedFrontCopies() {
        var queue = AtriaFIFOBuffer<Int>()
        for value in 0..<10_000 { queue.append(value) }
        for value in 0..<10_000 { XCTAssertEqual(queue.popFirst(), value) }
        XCTAssertTrue(queue.isEmpty)
        queue.append(42)
        XCTAssertEqual(queue.first, 42)
        queue.removeAll(keepingCapacity: true)
        XCTAssertEqual(queue.count, 0)
    }
}
