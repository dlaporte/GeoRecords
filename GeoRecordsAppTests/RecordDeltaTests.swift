//
//  RecordDeltaTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

struct RecordDeltaTests {

    @Test func latitudeDeltaIsMetersAlongAMeridian() async throws {
        let m = try #require(RecordDelta.meters(type: .north, from: 60.0, to: 61.0, atLatitude: 61.0))
        #expect(abs(m - 111_195) < 50)
        // South records improve downward: 61 -> 60 is one degree of progress
        let s = try #require(RecordDelta.meters(type: .south, from: 61.0, to: 60.0, atLatitude: 60.0))
        #expect(abs(s - 111_195) < 50)
    }

    @Test func longitudeDeltaShrinksWithLatitude() async throws {
        let equator = try #require(RecordDelta.meters(type: .east, from: 10.0, to: 11.0, atLatitude: 0))
        let sixty = try #require(RecordDelta.meters(type: .east, from: 10.0, to: 11.0, atLatitude: 60))
        #expect(abs(equator - 111_195) < 50)
        #expect(abs(sixty - 55_597) < 50)
    }

    @Test func verticalAndHomeDeltasPassThroughAndRegionsHaveNone() async throws {
        #expect(RecordDelta.meters(type: .up, from: 100, to: 350, atLatitude: 0) == 250)
        #expect(RecordDelta.meters(type: .fromHome, from: 5_000, to: 8_000, atLatitude: 0) == 3_000)
        #expect(RecordDelta.meters(type: .state, from: 0, to: 1, atLatitude: 0) == nil)
        // A less extreme "newer" value is negative progress
        #expect(RecordDelta.meters(type: .up, from: 350, to: 100, atLatitude: 0) == -250)
    }

    @Test func formattingUsesElevationUnitsForUpAndDistanceOtherwise() async throws {
        #expect(RecordDelta.format(meters: 304.8, type: .up, unitSystem: .imperial) == "1,000 ft")
        #expect(RecordDelta.format(meters: 341_174, type: .north, unitSystem: .imperial) == "212 mi")
        #expect(RecordDelta.format(meters: 3_219, type: .east, unitSystem: .imperial) == "2.0 mi")
        #expect(RecordDelta.format(meters: 12_000, type: .fromHome, unitSystem: .metric) == "12 km")
    }

    @Test func eastWestDistanceIsSignedAlongTheFirstPointsLatitude() async throws {
        let home = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
        let east = CLLocationCoordinate2D(latitude: 47.6, longitude: -121.3)
        let west = CLLocationCoordinate2D(latitude: 47.6, longitude: -123.3)
        #expect(eastWestDistance(from: home, to: east) > 0)
        #expect(eastWestDistance(from: home, to: west) < 0)
        // CLLocation measures on the WGS84 ellipsoid, about 0.3% off the spherical constant here
        #expect(abs(eastWestDistance(from: home, to: east) - 111_195 * cos(47.6 * .pi / 180)) < 300)
    }
}
