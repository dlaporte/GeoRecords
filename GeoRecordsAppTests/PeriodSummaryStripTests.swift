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

    // A type holds one lifetime record at a time, so beating "Furthest North" five
    // times in a year is one lifetime record set, not five: only the final record
    // of each type counts, dated when it was set, so the chart bars add up to the
    // headline. Yearly and lifetime are counted separately.
    @Test func countedEventsKeepOnlyTheFinalRecordPerType() async throws {
        let events = [
            RecordEvent(recordType: .north, timestamp: noon(2026, 2, 1), timeFrame: .allTime),
            RecordEvent(recordType: .north, timestamp: noon(2026, 5, 1), timeFrame: .allTime),
            RecordEvent(recordType: .north, timestamp: noon(2026, 9, 1), timeFrame: .allTime),
            RecordEvent(recordType: .east, timestamp: noon(2026, 3, 1), timeFrame: .allTime),
            RecordEvent(recordType: .north, timestamp: noon(2026, 10, 1), timeFrame: .year),
            RecordEvent(recordType: .north, timestamp: noon(2026, 10, 2), timeFrame: .year)
        ]
        let year = StatsRecordCounts.counted(events, in: .year)
        #expect(year.map(\.recordType) == [.east, .north])
        #expect(year.map(\.timestamp) == [noon(2026, 3, 1), noon(2026, 9, 1)])

        let month = StatsRecordCounts.counted(events, in: .month)
        #expect(month.map { ($0.recordType, $0.timeFrame) }.map { "\($0.0.rawValue)/\($0.1.rawValue)" }
                == ["Furthest East/Lifetime", "Furthest North/Lifetime", "Furthest North/Yearly"])
        #expect(month.last?.timestamp == noon(2026, 10, 2))
    }
}
