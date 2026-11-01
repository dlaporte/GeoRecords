//
//  RegionPeriodCounts.swift
//  GeoRecords
//
//  Region counts over a period, with the same exclusions as the Regions tab
//  (DC and territories never count as states, territories never as countries).
//

import Foundation

struct RegionPeriodCounts: Equatable {
    var states: Int
    var countries: Int
    var continents: Int
}

extension RegionTrackingManager {

    /// Regions first visited inside the interval (start inclusive, end exclusive)
    nonisolated static func newRegionCounts(in interval: DateInterval,
                                            states: [RecordDetail],
                                            countries: [RecordDetail],
                                            continents: [RecordDetail]) -> RegionPeriodCounts {
        func count(_ rows: [RecordDetail], type: RecordType) -> Int {
            let inPeriod = rows.filter { $0.timestamp >= interval.start && $0.timestamp < interval.end }
            return countUniqueRegions(inPeriod.map { (regionCode: $0.regionCode, locationName: $0.locationName) }, type: type)
        }
        return RegionPeriodCounts(states: count(states, type: .state),
                                  countries: count(countries, type: .country),
                                  continents: count(continents, type: .continent))
    }

    /// Running totals of states and countries visited on or before each date
    nonisolated static func cumulativeCounts(through dates: [Date],
                                             states: [RecordDetail],
                                             countries: [RecordDetail]) -> [(date: Date, states: Int, countries: Int)] {
        dates.map { date in
            let stateRows = states.filter { $0.timestamp <= date }.map { (regionCode: $0.regionCode, locationName: $0.locationName) }
            let countryRows = countries.filter { $0.timestamp <= date }.map { (regionCode: $0.regionCode, locationName: $0.locationName) }
            return (date: date,
                    states: countUniqueRegions(stateRows, type: .state),
                    countries: countUniqueRegions(countryRows, type: .country))
        }
    }

    func newRegionCounts(in interval: DateInterval) -> RegionPeriodCounts {
        Self.newRegionCounts(in: interval, states: visitedStates, countries: visitedCountries, continents: visitedContinents)
    }

    func cumulativeRegionCounts(through dates: [Date]) -> [(date: Date, states: Int, countries: Int)] {
        Self.cumulativeCounts(through: dates, states: visitedStates, countries: visitedCountries)
    }
}
