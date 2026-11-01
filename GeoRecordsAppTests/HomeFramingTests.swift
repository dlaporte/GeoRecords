//
//  HomeFramingTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

struct HomeFramingTests {

    private let home = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)

    private func record(_ type: RecordType, lat: Double, lon: Double) -> RecordDetail {
        RecordDetail(value: type == .north || type == .south ? lat : lon, timestamp: noon(2026, 10, 10),
                     coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                     altitude: 0, locationName: nil, recordType: type.rawValue)
    }

    // Cards say "312 mi north of home" instead of raw coordinates, sign-aware
    @Test func latitudeRecordsReadNorthOrSouthOfHome() async throws {
        let north = HomeFraming.text(for: record(.north, lat: 50.0, lon: -122.3), home: home, unitSystem: .imperial)
        #expect(north.label == "From Home")
        #expect(north.value == "166 mi north of home")
        // A Furthest North record set south of home still tells the truth
        let south = HomeFraming.text(for: record(.north, lat: 45.0, lon: -122.3), home: home, unitSystem: .imperial)
        #expect(south.value.hasSuffix(" south of home"))
    }

    @Test func longitudeRecordsReadEastOrWestOfHome() async throws {
        let west = HomeFraming.text(for: record(.west, lat: 47.6, lon: -124.0), home: home, unitSystem: .metric)
        #expect(west.label == "From Home")
        #expect(west.value.hasSuffix(" km west of home"))
    }

    @Test func otherTypesAndNoHomeFallBackToCardinalCoordinates() async throws {
        let up = HomeFraming.text(for: record(.up, lat: 46.85, lon: -121.76), home: home, unitSystem: .imperial)
        #expect(up.label == "Coordinates")
        #expect(up.value == "46.8500° N, 121.7600° W")
        let noHome = HomeFraming.text(for: record(.north, lat: 50.0, lon: -122.3), home: nil, unitSystem: .imperial)
        #expect(noHome.label == "Coordinates")
    }
}
