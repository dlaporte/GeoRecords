//
//  RegionPeriodCountTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

struct RegionPeriodCountTests {

    private func region(_ type: RecordType, code: String, name: String, _ date: Date) -> RecordDetail {
        RecordDetail(value: date.timeIntervalSince1970, timestamp: date,
                     coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -100),
                     altitude: 0, locationName: name, recordType: type.rawValue, regionCode: code)
    }

    // Period counts apply the same exclusions as the Regions tab: DC and territories
    // never count as states, territories never count as countries
    @Test func newRegionCountsRespectThePeriodAndTheTabRules() async throws {
        let states = [
            region(.state, code: "US-WA", name: "Washington", noon(2026, 10, 5)),
            region(.state, code: "US-DC", name: "District of Columbia", noon(2026, 10, 6)),
            region(.state, code: "US-OR", name: "Oregon", noon(2026, 9, 1))
        ]
        let countries = [
            region(.country, code: "JP", name: "Japan", noon(2026, 10, 7)),
            region(.country, code: "GL", name: "Greenland", noon(2026, 10, 8))  // territory of Denmark, never counted
        ]
        let continents = [region(.continent, code: "Asia", name: "Asia", noon(2026, 10, 7))]
        let october = DateInterval(start: noon(2026, 10, 1), end: noon(2026, 11, 1))

        let counts = RegionTrackingManager.newRegionCounts(in: october, states: states, countries: countries, continents: continents)
        #expect(counts == RegionPeriodCounts(states: 1, countries: 1, continents: 1))
    }

    @Test func cumulativeCountsStepUpThroughTime() async throws {
        let states = [
            region(.state, code: "US-OR", name: "Oregon", noon(2026, 9, 1)),
            region(.state, code: "US-WA", name: "Washington", noon(2026, 10, 5))
        ]
        let countries = [region(.country, code: "JP", name: "Japan", noon(2026, 10, 7))]
        let points = RegionTrackingManager.cumulativeCounts(through: [noon(2026, 9, 30), noon(2026, 10, 31)], states: states, countries: countries)
        #expect(points.map(\.states) == [1, 2])
        #expect(points.map(\.countries) == [0, 1])
    }
}
