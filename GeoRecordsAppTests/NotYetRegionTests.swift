//
//  NotYetRegionTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

struct NotYetRegionTests {

    @Test func remainingKeepsOrderAndDropsVisited() async throws {
        let all = [NotYetRegion(code: "US-AL", name: "Alabama"), NotYetRegion(code: "US-AK", name: "Alaska"), NotYetRegion(code: "US-AZ", name: "Arizona")]
        let remaining = NotYetSet.remaining(all: all, visitedCodes: ["US-AK"])
        #expect(remaining.map(\.code) == ["US-AL", "US-AZ"])
    }

    @Test func referenceListsMatchTheTabTotals() async throws {
        #expect(NotYetSet.allStates.count == 50)
        #expect(NotYetSet.allCountries.count == 195)
        #expect(NotYetSet.allContinents.count == 7)
        #expect(NotYetSet.allStates.first?.name == "Alabama")
    }

    @Test func nearestDistanceUsesTheClosestVertex() async throws {
        let home = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
        let polygons: [[[CLLocationCoordinate2D]]] = [[[
            CLLocationCoordinate2D(latitude: 46.0, longitude: -122.3),   // ~178 km south
            CLLocationCoordinate2D(latitude: 45.0, longitude: -122.3),
            CLLocationCoordinate2D(latitude: 45.0, longitude: -120.0)
        ]]]
        let meters = try #require(RegionDistance.nearestMeters(from: home, polygons: polygons))
        #expect(abs(meters - 178_000) < 2_000)
        #expect(RegionDistance.nearestMeters(from: home, polygons: []) == nil)
    }

    // "~90 mi away": one figure below 100, two above
    @Test func approximateDistanceRoundsForReading() async throws {
        #expect(RegionDistance.approximateText(meters: 87 * metersPerMile, unitSystem: .imperial) == "~90 mi away")
        #expect(RegionDistance.approximateText(meters: 1_234 * metersPerMile, unitSystem: .imperial) == "~1,200 mi away")
        #expect(RegionDistance.approximateText(meters: 5.4 * metersPerKm, unitSystem: .metric) == "~5 km away")
        #expect(RegionDistance.approximateText(meters: 456 * metersPerKm, unitSystem: .metric) == "~460 km away")
    }
}
