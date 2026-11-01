//
//  VisitLogTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

struct VisitLogTests {

    // Live tracking counts arrivals: a fix in the same region as the last fix is
    // not a new visit, a fix in a different region is, and the first fix ever is
    @Test func liveFixesCountArrivalsNotDays() async throws {
        let today = noon(2026, 10, 10)
        #expect(VisitLog.shouldLogArrival(previousRegionCode: "US-WA", newRegionCode: "US-WA",
                                          existingDates: [], date: today, source: .location) == false)
        #expect(VisitLog.shouldLogArrival(previousRegionCode: "US-OR", newRegionCode: "US-WA",
                                          existingDates: [noon(2026, 10, 9)], date: today, source: .location) == true)
        #expect(VisitLog.shouldLogArrival(previousRegionCode: nil, newRegionCode: "US-WA",
                                          existingDates: [], date: today, source: .location) == true)
    }

    // Photos (and manual or wizard entries) count a day with no earlier visit
    @Test func photosCountOnePerDay() async throws {
        let morning = noon(2026, 10, 10).addingTimeInterval(-3 * 3600)
        let afternoon = noon(2026, 10, 10).addingTimeInterval(3 * 3600)
        #expect(VisitLog.shouldLogArrival(previousRegionCode: nil, newRegionCode: "JP",
                                          existingDates: [morning], date: afternoon, source: .photo) == false)
        #expect(VisitLog.shouldLogArrival(previousRegionCode: nil, newRegionCode: "JP",
                                          existingDates: [morning], date: noon(2026, 10, 12), source: .photo) == true)
        #expect(VisitLog.shouldLogArrival(previousRegionCode: "JP", newRegionCode: "JP",
                                          existingDates: [], date: noon(2026, 10, 12), source: .manual) == true)
    }

    @Test func summaryCountsVisitsAndRemembersTheLatest() async throws {
        let summary = VisitLog.summary(dates: [noon(2024, 6, 3), noon(2026, 8, 20), noon(2025, 1, 1)])
        #expect(summary.count == 3)
        #expect(summary.last == noon(2026, 8, 20))
        #expect(VisitLog.summary(dates: []).last == nil)
    }

    @Test func visitKeysUseTheRecordRowsNormalizedCode() async throws {
        #expect(VisitLog.key(code: "WA", type: .state) == VisitLog.Key(regionType: "state", regionCode: "US-WA"))
        #expect(VisitLog.key(code: "US-WA", type: .state) == VisitLog.Key(regionType: "state", regionCode: "US-WA"))
        #expect(VisitLog.key(code: "JP", type: .country) == VisitLog.Key(regionType: "country", regionCode: "JP"))
        #expect(VisitLog.key(code: "Asia", type: .continent) == VisitLog.Key(regionType: "continent", regionCode: "Asia"))
    }
}
