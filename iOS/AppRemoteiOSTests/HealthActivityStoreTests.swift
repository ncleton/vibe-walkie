import Foundation
import HealthKit
import RemoteCore
import XCTest
@testable import VibeWalkieiOS

@MainActor
final class HealthActivityStoreTests: XCTestCase {
    func testLegacyStepAuthorizationStillUnlocksHealthReads() throws {
        let suiteName = "HealthActivityStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "vibe.walkie.health.authorization-requested.v1")

        XCTAssertTrue(HealthActivityStore.authorizationWasRequested(in: defaults))
    }

    func testHealthAuthorizationIsNotAssumedWithoutARecordedRequest() throws {
        let suiteName = "HealthActivityStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(HealthActivityStore.authorizationWasRequested(in: defaults))
    }

    func testHealthQueriesIncludeSamplesThatOverlapWorkSessionBoundaries() {
        XCTAssertEqual(HealthActivityStore.sampleQueryOptions, [])
    }

    func testOverlappingWorkSessionsAreMergedBeforeQueryingHealthKit() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let sessions = [
            DateInterval(
                start: base.addingTimeInterval(10),
                end: base.addingTimeInterval(80)
            ),
            DateInterval(
                start: base.addingTimeInterval(60),
                end: base.addingTimeInterval(120)
            )
        ]

        let intervals = HealthActivityStore.mergedIntervals(
            from: sessions,
            boundedBy: DateInterval(start: base, end: base.addingTimeInterval(200))
        )

        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].start, base.addingTimeInterval(10))
        XCTAssertEqual(intervals[0].end, base.addingTimeInterval(120))
    }

    func testSessionsAreClippedToTheSelectedDay() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let session = DateInterval(
            start: base.addingTimeInterval(-30),
            end: base.addingTimeInterval(60)
        )

        let intervals = HealthActivityStore.mergedIntervals(
            from: [session],
            boundedBy: DateInterval(start: base, end: base.addingTimeInterval(300))
        )

        XCTAssertEqual(intervals, [DateInterval(start: base, end: base.addingTimeInterval(60))])
    }

    func testLifePointsUseOnePointPerHundredAttributedSteps() {
        let summary = WorkWalkingDaySummary(
            day: Date(),
            workSteps: 1_275,
            totalSteps: 8_000,
            workSessionDuration: 1_800,
            briskWalkingMinutes: 12,
            walkingDistanceMeters: 920
        )

        XCTAssertEqual(summary.lifePoints, 12.75, accuracy: 0.001)
    }

    func testDailyLongevityProjectionUsesFiveWorkDaysAndPublishedThresholds() {
        let projectedWeek = 30.0 * 5
        let result = EvidenceBasedLongevityEstimate(
            weeklyBriskWalkingMinutes: projectedWeek
        ).result

        XCTAssertEqual(result?.associatedYears, 3.4)
        XCTAssertEqual(result?.confidenceInterval, 3.2...3.6)
    }

    func testDailyLongevityProjectionNeverExceedsPublishedMaximum() {
        let projectedWeek = 10.0 * 60 * 5
        let result = EvidenceBasedLongevityEstimate(
            weeklyBriskWalkingMinutes: projectedWeek
        ).result

        XCTAssertEqual(result?.associatedYears, 4.5)
        XCTAssertEqual(result?.confidenceInterval, 4.3...4.7)
    }

    func testMissingHealthIntensityDoesNotProduceLongevityProjection() {
        XCTAssertNil(
            EvidenceBasedLongevityEstimate(weeklyBriskWalkingMinutes: nil).result
        )
    }

    func testWeekHistoryContainsSevenChronologicalDays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_780_012_800)
        let today = calendar.startOfDay(for: now)
        let days = (0..<10).compactMap { offset -> WorkWalkingDaySummary? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return makeSummary(day: date, steps: (offset + 1) * 100)
        }

        let points = HealthHistoryAggregator.points(
            from: days,
            period: .week,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points.map(\.workSteps), [700, 600, 500, 400, 300, 200, 100])
    }

    func testYearHistoryUsesMonthlyDailyAverages() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6)))
        let augustFirst = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let days = [
            makeSummary(day: augustFirst, steps: 1_000),
            makeSummary(
                day: try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: augustFirst)),
                steps: 3_000
            ),
            makeSummary(day: now, steps: 1_500)
        ]

        let points = HealthHistoryAggregator.points(
            from: days,
            period: .year,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(points.count, 12)
        XCTAssertEqual(points[10].workSteps, 2_000)
        XCTAssertEqual(points[10].representedDayCount, 2)
        XCTAssertEqual(points[11].workSteps, 1_500)
    }

    private func makeSummary(day: Date, steps: Int) -> WorkWalkingDaySummary {
        WorkWalkingDaySummary(
            day: day,
            workSteps: steps,
            totalSteps: 0,
            workSessionDuration: 0,
            briskWalkingMinutes: nil,
            walkingDistanceMeters: 0
        )
    }
}
