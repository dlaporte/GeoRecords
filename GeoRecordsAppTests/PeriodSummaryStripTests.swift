//
//  PeriodSummaryStripTests.swift
//  GeoRecordsTests
//

import Testing
@testable import GeoRecords

struct PeriodSummaryStripTests {

    // Records of the browsed period's own timeframe are set every period by the
    // first fix, so only the larger timeframes are worth a count: yearly and
    // lifetime in a month, lifetime in a year, none in Lifetime
    @Test func periodStripCountsOnlyLargerTimeframeRecords() async throws {
        #expect(PeriodSummary.text(title: "Oct 2026", view: .month, yearlyRecords: 3, lifetimeRecords: 1, states: 1, countries: 0, continents: 0)
                == "Oct 2026 · 3 yearly records set · 1 lifetime record set · 1 new state")
        #expect(PeriodSummary.text(title: "This Year", view: .year, yearlyRecords: 0, lifetimeRecords: 4, states: 4, countries: 2, continents: 1)
                == "This Year · 4 lifetime records set · 4 new states · 2 new countries · 1 new continent")
        #expect(PeriodSummary.text(title: "This Month", view: .month, yearlyRecords: 1, lifetimeRecords: 0, states: 0, countries: 0, continents: 0)
                == "This Month · 1 yearly record set")
    }

    @Test func lifetimeStripShowsRegionTotalsOnly() async throws {
        #expect(PeriodSummary.text(title: "Lifetime", view: .allTime, yearlyRecords: 0, lifetimeRecords: 0, states: 14, countries: 9, continents: 3)
                == "Lifetime · 14 states · 9 countries · 3 continents")
    }

    // An ordinary month full of monthly records is not "nothing recorded"
    @Test func emptyPeriodSaysWhatIsMissing() async throws {
        #expect(PeriodSummary.text(title: "Oct 2026", view: .month, yearlyRecords: 0, lifetimeRecords: 0, states: 0, countries: 0, continents: 0)
                == "Oct 2026 · no yearly or lifetime records · no new regions")
        #expect(PeriodSummary.text(title: "2024", view: .year, yearlyRecords: 0, lifetimeRecords: 0, states: 0, countries: 0, continents: 0)
                == "2024 · no lifetime records · no new regions")
        #expect(PeriodSummary.text(title: "Lifetime", view: .allTime, yearlyRecords: 0, lifetimeRecords: 0, states: 0, countries: 0, continents: 0)
                == "Lifetime · no regions yet")
    }

    @Test func countedTimeFramesAreTheLargerOnes() async throws {
        #expect(StatsRecordCounts.countedTimeFrames(for: .month) == [.year, .allTime])
        #expect(StatsRecordCounts.countedTimeFrames(for: .year) == [.allTime])
        #expect(StatsRecordCounts.countedTimeFrames(for: .allTime).isEmpty)
    }

    @Test func countedEventsKeepOnlyLargerTimeframes() async throws {
        let t = noon(2026, 10, 10)
        let events = [
            RecordEvent(recordType: .north, timestamp: t, timeFrame: .month),
            RecordEvent(recordType: .east, timestamp: t, timeFrame: .year),
            RecordEvent(recordType: .up, timestamp: t, timeFrame: .allTime)
        ]
        #expect(StatsRecordCounts.counted(events, in: .month).map(\.recordType) == [.east, .up])
        #expect(StatsRecordCounts.counted(events, in: .year).map(\.recordType) == [.up])
        #expect(StatsRecordCounts.counted(events, in: .allTime).isEmpty)
    }
}
