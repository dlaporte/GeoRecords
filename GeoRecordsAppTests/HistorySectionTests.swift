//
//  HistorySectionTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

@MainActor
struct HistorySectionTests {

    // Sections follow the list's newest-first order and rows keep the flat index
    // the detail pager opens at
    @Test func groupsByMonthNewestFirstKeepingFlatIndices() async throws {
        let ctx = try makeInMemoryContext()
        let a = insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 70, lat: 70, lon: 10, timestamp: noon(2026, 10, 20))
        let b = insertRow(ctx, type: "Furthest Up", timeFrame: "Monthly", value: 500, lat: 46, lon: -121, timestamp: noon(2026, 10, 5))
        let c = insertRow(ctx, type: "Furthest West", timeFrame: "Yearly", value: -124, lat: 48, lon: -124, timestamp: noon(2026, 9, 30))
        let d = insertRow(ctx, type: "Furthest East", timeFrame: "Yearly", value: -100, lat: 40, lon: -100, timestamp: noon(2026, 9, 1))
        d.timestamp = nil

        let sections = HistorySections.group([a, b, c, d])
        #expect(sections.map(\.title) == ["October 2026", "September 2026", "Undated"])
        #expect(sections[0].rows.map(\.index) == [0, 1])
        #expect(sections[1].rows.map(\.index) == [2])
        #expect(sections[2].rows.map(\.index) == [3])
    }

    @Test func sourceFilterBucketsRowsWithoutASource() async throws {
        #expect(HistorySourceFilter.all.matches(nil))
        #expect(HistorySourceFilter.source(.photo).matches("photo"))
        #expect(HistorySourceFilter.source(.photo).matches("location") == false)
        #expect(HistorySourceFilter.unknown.matches(nil))
        #expect(HistorySourceFilter.unknown.matches("legacy-value"))
        #expect(HistorySourceFilter.unknown.matches("photo") == false)
        #expect(HistorySourceFilter.menuOrder.first == .all)
        #expect(HistorySourceFilter.menuOrder.last == .unknown)
    }
}
