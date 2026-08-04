import XCTest
@testable import Atria

final class PhysicalSleepProbeTests: XCTestCase {
    func testPrintCurrentPhysicalSleepCandidates() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/atria-sleep-audit.8yTv0k/sessions.json"))
        let sessions = try JSONDecoder().decode([SavedSession].self, from: data)
        let candidates = SessionStore.aggregateSleepCandidates(
            in: sessions,
            rest: 62,
            maxHR: 190,
            calendar: .current,
            historicalMotionPolicy: .sessionOnly
        )
        for candidate in candidates {
            print("PHYSICAL_SLEEP_CANDIDATE kind=\(candidate.kind) start=\(candidate.start) end=\(candidate.end) duration=\(candidate.duration) span=\(candidate.span) avg=\(candidate.avgHR) median=\(candidate.medianHR) p90=\(candidate.hrP90) review=\(SessionStore.isReviewWorthySleepCandidate(candidate)) auto=\(SessionStore.isAutoConfirmableMainSleepCandidate(candidate, baselineRestingIsTrusted: true))")
        }
    }
}
