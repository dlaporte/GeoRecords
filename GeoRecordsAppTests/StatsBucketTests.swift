//
//  StatsBucketTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

struct StatsBucketTests {
    let calendar = Calendar.current

    @Test func monthBucketsAreTheDaysOfTheBrowsedMonth() async throws {
        let starts = StatsBuckets.bucketStarts(timeFrame: .month, year: nil, month: MonthSelection(year: 2026, month: 10),
                                               now: noon(2026, 11, 1), earliestYear: nil, calendar: calendar)
        #expect(starts.count == 31)
        #expect(starts.first == calendar.startOfDay(for: noon(2026, 10, 1)))
        #expect(StatsBuckets.labels(for: starts, timeFrame: .month, calendar: calendar).prefix(3) == ["1", "2", "3"])
    }

    @Test func yearBucketsAreTwelveMonthsAndLifetimeRunsFromTheEarliestYear() async throws {
        let year = StatsBuckets.bucketStarts(timeFrame: .year, year: 2024, month: nil,
                                             now: noon(2026, 11, 1), earliestYear: nil, calendar: calendar)
        #expect(year.count == 12)
        #expect(StatsBuckets.labels(for: year, timeFrame: .year, calendar: calendar).first == "Jan")

        let lifetime = StatsBuckets.bucketStarts(timeFrame: .allTime, year: nil, month: nil,
                                                 now: noon(2026, 11, 1), earliestYear: 2019, calendar: calendar)
        #expect(lifetime.count == 8)
        #expect(StatsBuckets.labels(for: lifetime, timeFrame: .allTime, calendar: calendar) == ["2019", "2020", "2021", "2022", "2023", "2024", "2025", "2026"])
    }

    @Test func countsFallIntoTheRightBucket() async throws {
        let starts = StatsBuckets.bucketStarts(timeFrame: .month, year: nil, month: MonthSelection(year: 2026, month: 10),
                                               now: noon(2026, 11, 1), earliestYear: nil, calendar: calendar)
        let dates = [noon(2026, 10, 3), noon(2026, 10, 3).addingTimeInterval(3600), noon(2026, 10, 20), noon(2026, 11, 2)]
        let counts = StatsBuckets.counts(dates: dates, bucketStarts: starts, component: .day, calendar: calendar)
        #expect(counts.count == 31)
        #expect(counts[2] == 2)
        #expect(counts[19] == 1)
        #expect(counts.reduce(0, +) == 3)
    }

    @Test func periodIntervalCoversTheBrowsedPeriod() async throws {
        let month = StatsBuckets.periodInterval(timeFrame: .month, year: nil, month: MonthSelection(year: 2026, month: 10),
                                                now: noon(2026, 11, 1), calendar: calendar)
        #expect(month.start == calendar.startOfDay(for: noon(2026, 10, 1)))
        #expect(month.end == calendar.startOfDay(for: noon(2026, 11, 1)))
        let lifetime = StatsBuckets.periodInterval(timeFrame: .allTime, year: nil, month: nil,
                                                   now: noon(2026, 11, 1), calendar: calendar)
        #expect(lifetime.start == .distantPast)
    }
}
