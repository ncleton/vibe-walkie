import RemoteCore
import XCTest
@testable import VibeWalkieMac

final class EvidenceBasedLongevityEstimateTests: XCTestCase {
    func testPublishedBriskWalkingThresholdsAreUsedWithoutInterpolation() {
        let cases: [(minutes: Double, years: Double, lower: Double, upper: Double)] = [
            (30, 1.8, 1.6, 2.0),
            (75, 2.5, 2.2, 2.7),
            (150, 3.4, 3.2, 3.6),
            (300, 4.2, 4.0, 4.5),
            (450, 4.5, 4.3, 4.7)
        ]

        for item in cases {
            let result = EvidenceBasedLongevityEstimate(
                weeklyBriskWalkingMinutes: item.minutes
            ).result

            XCTAssertEqual(result?.associatedYears, item.years)
            XCTAssertEqual(result?.confidenceInterval?.lowerBound, item.lower)
            XCTAssertEqual(result?.confidenceInterval?.upperBound, item.upper)
        }
    }

    func testDemoWeekUsesHighestPublishedCategory() {
        let estimate = EvidenceBasedLongevityEstimate(
            weeklyBriskWalkingMinutes: 28.25 * 60
        )

        XCTAssertEqual(estimate.result?.associatedYears, 4.5)
        XCTAssertEqual(estimate.result?.confidenceInterval, 4.3...4.7)
    }

    func testTenHoursPerDayNeverExceedsThePublishedMaximum() {
        let estimate = EvidenceBasedLongevityEstimate(
            weeklyBriskWalkingMinutes: 10 * 60 * 7
        )

        XCTAssertEqual(estimate.result?.associatedYears, 4.5)
        XCTAssertEqual(estimate.result?.confidenceInterval, 4.3...4.7)
    }

    func testNonPositiveWalkingHasNoAssociatedGain() {
        for minutes in [0.0, -60.0] {
            let result = EvidenceBasedLongevityEstimate(
                weeklyBriskWalkingMinutes: minutes
            ).result

            XCTAssertEqual(result?.associatedYears, 0)
            XCTAssertNil(result?.confidenceInterval)
        }
    }

    func testMissingHealthIntensityDoesNotProduceAnEstimate() {
        let estimate = EvidenceBasedLongevityEstimate(weeklyBriskWalkingMinutes: nil)

        XCTAssertNil(estimate.result)
    }
}
