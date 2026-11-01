//
//  SummaryNotificationPlanTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

struct SummaryNotificationPlanTests {

    // Since 1.8.0 every launch scheduled a precise "October Summary" AND a
    // repeating generic fallback five minutes later, so two banners arrived on
    // the 1st. The replacement: a rolling window of precise requests, one per
    // upcoming month boundary, plus the next yearly one.
    @Test func summaryPlanCoversNextTwelveMonthsAndNextYearWithUniqueIds() async throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10)))
        let plan = SummaryNotificationManager.plannedSummaries(from: now, calendar: calendar)

        let monthly = plan.filter { $0.statsMonth != nil }
        let yearly = plan.filter { $0.statsMonth == nil }
        #expect(monthly.count == 12)
        #expect(yearly.count == 1)
        #expect(Set(plan.map { $0.identifier }).count == 13)

        // First monthly fires Dec 1 08:00 and summarizes November
        let first = try #require(monthly.first)
        #expect(first.identifier == "monthly-summary-2026-11")
        #expect(first.title == "November Summary")
        #expect(first.statsYear == 2026 && first.statsMonth == 11)
        #expect((first.fireDate.year, first.fireDate.month, first.fireDate.day, first.fireDate.hour, first.fireDate.minute)
                == (2026, 12, 1, 8, 0))

        // Last monthly summarizes October 2027 and fires Nov 1 2027
        let last = try #require(monthly.last)
        #expect(last.identifier == "monthly-summary-2027-10")
        #expect((last.fireDate.year, last.fireDate.month) == (2027, 11))

        // Yearly fires Jan 1 2027 at 08:05 (staggered after the December monthly)
        let year = try #require(yearly.first)
        #expect(year.identifier == "yearly-summary-2026")
        #expect(year.title == "2026 Year in Review")
        #expect(year.statsYear == 2026)
        #expect((year.fireDate.year, year.fireDate.month, year.fireDate.day, year.fireDate.hour, year.fireDate.minute)
                == (2027, 1, 1, 8, 5))
    }

    @Test func summaryPlanOnTheFirstBeforeEightStillIncludesThatMorning() async throws {
        let calendar = Calendar.current
        let early = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 7)))
        let earlyPlan = SummaryNotificationManager.plannedSummaries(from: early, calendar: calendar)
        #expect(earlyPlan.first { $0.statsMonth != nil }?.identifier == "monthly-summary-2026-12")
        #expect(earlyPlan.first { $0.statsMonth == nil }?.identifier == "yearly-summary-2026")

        // After 08:05 on Jan 1 both of that morning's requests are in the past
        let late = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 9)))
        let latePlan = SummaryNotificationManager.plannedSummaries(from: late, calendar: calendar)
        #expect(latePlan.first { $0.statsMonth != nil }?.identifier == "monthly-summary-2027-01")
        #expect(latePlan.first { $0.statsMonth == nil }?.identifier == "yearly-summary-2027")
    }
}
