//
//  PeriodSummaryStripTests.swift
//  GeoRecordsTests
//

import Testing
@testable import GeoRecords

struct PeriodSummaryStripTests {

    @Test func periodStripNamesWhatHappened() async throws {
        #expect(PeriodSummary.text(title: "Oct 2026", records: 3, states: 1, countries: 0, continents: 0, lifetime: false)
                == "Oct 2026 · 3 records set · 1 new state")
        #expect(PeriodSummary.text(title: "This Year", records: 41, states: 4, countries: 2, continents: 1, lifetime: false)
                == "This Year · 41 records set · 4 new states · 2 new countries · 1 new continent")
        #expect(PeriodSummary.text(title: "This Month", records: 1, states: 0, countries: 0, continents: 0, lifetime: false)
                == "This Month · 1 record set")
    }

    @Test func lifetimeStripShowsTotals() async throws {
        #expect(PeriodSummary.text(title: "Lifetime", records: 180, states: 14, countries: 9, continents: 3, lifetime: true)
                == "Lifetime · 180 records set · 14 states · 9 countries · 3 continents")
    }

    @Test func emptyPeriodSaysSo() async throws {
        #expect(PeriodSummary.text(title: "Oct 2026", records: 0, states: 0, countries: 0, continents: 0, lifetime: false)
                == "Oct 2026 · nothing recorded")
    }
}
