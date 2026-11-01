//
//  ManualEntryTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

struct ManualEntryTests {

    // A hand-entered 2015 location was only ever compared against the lifetime
    // slot, so it never showed under 2015. Every entry evaluates its own
    // month, its own year, and lifetime; only current periods touch the
    // in-memory slots.
    @Test func manualEntryEvaluatesItsOwnMonthYearAndLifetime() async throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))

        let past = try #require(calendar.date(from: DateComponents(year: 2015, month: 6, day: 10)))
        #expect(ManualEntryPlanner.periodSlots(for: past, now: now, calendar: calendar) == [
            .init(timeFrame: .month, isCurrentPeriod: false),
            .init(timeFrame: .year, isCurrentPeriod: false),
            .init(timeFrame: .allTime, isCurrentPeriod: true)
        ])

        let thisYear = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 5)))
        #expect(ManualEntryPlanner.periodSlots(for: thisYear, now: now, calendar: calendar) == [
            .init(timeFrame: .month, isCurrentPeriod: false),
            .init(timeFrame: .year, isCurrentPeriod: true),
            .init(timeFrame: .allTime, isCurrentPeriod: true)
        ])

        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
        #expect(ManualEntryPlanner.periodSlots(for: today, now: now, calendar: calendar).allSatisfy { $0.isCurrentPeriod })
    }
}
