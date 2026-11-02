//
//  TabStateTests.swift
//  GeoRecordsTests
//

import Testing
@testable import GeoRecords

// Tab state lives above the views so both layouts share it; deep links land in it
struct TabStateTests {

    @Test func regionsDeepLinkSelectsTheSection() async throws {
        let state = RegionsTabState()
        state.apply(section: "continents")
        #expect(state.mapType == .continents)
        state.apply(section: "nonsense")
        #expect(state.mapType == .continents)
        state.apply(section: "states")
        #expect(state.mapType == .states)
    }

    @Test func recordsDeepLinkTargetsTheCurrentPeriod() async throws {
        let state = RecordsTabState()
        state.timeFrame = .year
        state.year = 2024
        state.month = MonthSelection(year: 2024, month: 3)
        state.apply(deepLinkTimeFrame: .month)
        #expect(state.timeFrame == .month)
        #expect(state.year == nil)
        #expect(state.month == nil)
    }
}
