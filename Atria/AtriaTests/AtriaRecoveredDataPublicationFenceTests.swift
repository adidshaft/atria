import XCTest
@testable import Atria

@MainActor
final class AtriaRecoveredDataPublicationFenceTests: XCTestCase {
    func testArchiveRevisionsAreMonotonicAndNoNewWorkReturnsImmediately() async {
        let fence = AtriaRecoveredDataPublicationFence()

        XCTAssertEqual(fence.recordArchiveUpdate(), 1)
        XCTAssertEqual(fence.recordArchiveUpdate(), 2)
        XCTAssertEqual(fence.archiveRevision, 2)
        let noWorkResult = await fence.awaitPublication(
            after: 2,
            timeout: .milliseconds(10)
        )
        XCTAssertTrue(noWorkResult)
    }

    func testPublicationResumesTargetWaiterAndAdvancesPublishedRevision() async {
        let fence = AtriaRecoveredDataPublicationFence()
        let revision = fence.recordArchiveUpdate()
        let result = Task { @MainActor in
            await fence.awaitPublication(after: 0, timeout: .seconds(1))
        }
        await Task.yield()

        fence.publish(through: revision)

        let publishedResult = await result.value
        XCTAssertTrue(publishedResult)
        XCTAssertEqual(fence.lastPublishedRevision, revision)
        let alreadyPublishedResult = await fence.awaitPublication(
            after: 0,
            timeout: .milliseconds(10)
        )
        XCTAssertTrue(alreadyPublishedResult)
    }

    func testFailureResumesFalseWithoutAdvancingPublishedRevision() async {
        let fence = AtriaRecoveredDataPublicationFence()
        let revision = fence.recordArchiveUpdate()
        let result = Task { @MainActor in
            await fence.awaitPublication(after: 0, timeout: .seconds(1))
        }
        await Task.yield()

        fence.fail(through: revision)

        let failedResult = await result.value
        XCTAssertFalse(failedResult)
        XCTAssertEqual(fence.lastPublishedRevision, 0)
    }

    func testTimeoutFailsUnpublishedWaiter() async {
        let fence = AtriaRecoveredDataPublicationFence()
        fence.recordArchiveUpdate()

        let timedOutResult = await fence.awaitPublication(
            after: 0,
            timeout: .milliseconds(10)
        )
        XCTAssertFalse(timedOutResult)
        XCTAssertEqual(fence.lastPublishedRevision, 0)
    }
}
