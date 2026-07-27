import XCTest
@testable import Atria

final class AtriaAthleteProfileProvenanceTests: XCTestCase {
    func testFreshInstallDefaultsToAgeEstimatedMaxHR() throws {
        let suite = "atria-athlete-profile-fresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let profile = AthleteProfile.load(userDefaults: defaults)

        XCTAssertEqual(profile.maxHRSource, .ageEstimate)
        XCTAssertEqual(profile.measuredMaxHR, 190,
                       "the placeholder may remain stored, but must not gain measured provenance")
        XCTAssertEqual(profile.maxHR, profile.ageEstimatedMaxHR)
    }

    func testFreshInstallLegacyScalarStillDefaultsToAgeEstimate() throws {
        let suite = "atria-athlete-profile-scalar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(201, forKey: "maxHR")

        let profile = AthleteProfile.load(userDefaults: defaults)

        XCTAssertEqual(profile.maxHRSource, .ageEstimate)
        XCTAssertEqual(profile.measuredMaxHR, 201)
        XCTAssertEqual(profile.maxHR, profile.ageEstimatedMaxHR,
                       "an unproven legacy scalar must not become the active measured HRmax")
    }

    func testLegacyProfileJSONWithoutSourceDefaultsToAgeEstimate() throws {
        let data = try XCTUnwrap("""
        {
          "age": 42,
          "measuredMaxHR": 197,
          "biologicalSex": "male",
          "weightKg": 78,
          "heightCm": 180,
          "hasCompletedOnboarding": true
        }
        """.data(using: .utf8))

        let profile = try JSONDecoder().decode(AthleteProfile.self, from: data)

        XCTAssertEqual(profile.maxHRSource, .ageEstimate)
        XCTAssertEqual(profile.measuredMaxHR, 197)
        XCTAssertEqual(profile.maxHR, profile.ageEstimatedMaxHR)
    }

    func testExplicitMeasuredProfileKeepsMeasuredProvenance() throws {
        let original = AthleteProfile(age: 36,
                                      measuredMaxHR: 194,
                                      maxHRSource: .measured,
                                      biologicalSex: .female,
                                      weightKg: 64,
                                      heightCm: 168,
                                      updated: Date(timeIntervalSince1970: 1_800_000_000),
                                      hasCompletedOnboarding: true)

        let decoded = try JSONDecoder().decode(
            AthleteProfile.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.maxHRSource, .measured)
        XCTAssertEqual(decoded.maxHR, 194)
    }
}
