//
//  RecordCaptionTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

struct RecordCaptionTests {

    private func record(_ type: RecordType, value: Double, lat: Double = 60, lon: Double = 10,
                        name: String? = nil, _ date: Date = noon(2026, 10, 10)) -> RecordDetail {
        RecordDetail(value: value, timestamp: date, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                     altitude: 0, locationName: name, recordType: type.rawValue)
    }

    // "Beat your previous by 212 mi (Tromsø, Jun 2024)": the card gets the short form,
    // the detail row the long one
    @Test func progressionNamesTheGapAndThePreviousPlace() async throws {
        let previous = record(.north, value: 66.5, lat: 66.5, name: "Tromsø", noon(2024, 6, 3))
        let current = record(.north, value: 69.5, lat: 69.5, name: "Nordkapp")
        #expect(RecordCaption.progression(current: current, previous: previous, unitSystem: .imperial) == "Beat previous by 207 mi")
        #expect(RecordCaption.progressionDetail(current: current, previous: previous, unitSystem: .imperial) == "207 mi (Tromsø, Jun 2024)")
        let unnamed = record(.north, value: 66.5, lat: 66.5, noon(2024, 6, 3))
        #expect(RecordCaption.progressionDetail(current: current, previous: unnamed, unitSystem: .imperial) == "207 mi (Jun 2024)")
    }

    @Test func progressionIsSilentWithoutAnImprovement() async throws {
        let current = record(.north, value: 69.5, lat: 69.5)
        #expect(RecordCaption.progression(current: current, previous: nil, unitSystem: .imperial) == nil)
        let better = record(.north, value: 70.0, lat: 70.0, noon(2024, 6, 3))
        #expect(RecordCaption.progression(current: current, previous: better, unitSystem: .imperial) == nil)
    }

    // "15 mi short of your yearly furthest east" on This Month cards
    @Test func withinReachNamesTheNearestTargetAhead() async throws {
        let month = record(.east, value: 10.0, lat: 0, lon: 10.0)
        let year = record(.east, value: 10.2, lat: 0, lon: 10.2)   // ~13.8 mi ahead
        let lifetime = record(.east, value: 12.0, lat: 0, lon: 12.0)
        #expect(RecordCaption.withinReach(month: month, year: year, lifetime: lifetime, unitSystem: .imperial)
                == "14 mi short of your yearly furthest east")
    }

    @Test func withinReachFallsThroughToLifetimeWhenMonthIsTheYearRecord() async throws {
        let month = record(.east, value: 10.2, lat: 0, lon: 10.2)
        let year = record(.east, value: 10.2, lat: 0, lon: 10.2)
        let lifetime = record(.east, value: 10.5, lat: 0, lon: 10.5)
        #expect(RecordCaption.withinReach(month: month, year: year, lifetime: lifetime, unitSystem: .imperial)
                == "21 mi short of your lifetime furthest east")
    }

    @Test func withinReachIsSilentWhenTheMonthLeadsOrTheGapIsLarge() async throws {
        let month = record(.east, value: 15.0, lat: 0, lon: 15.0)
        let year = record(.east, value: 10.0, lat: 0, lon: 10.0)
        #expect(RecordCaption.withinReach(month: month, year: year, lifetime: year, unitSystem: .imperial) == nil)
        let far = record(.east, value: 30.0, lat: 0, lon: 30.0)
        #expect(RecordCaption.withinReach(month: year, year: far, lifetime: far, unitSystem: .imperial) == nil)
    }

    @Test func withinReachUsesTheElevationThresholdForUp() async throws {
        let month = record(.up, value: 1_000)
        let near = record(.up, value: 1_200)     // 656 ft short: within 1,000 ft
        let far = record(.up, value: 1_400)      // 1,312 ft short: beyond
        #expect(RecordCaption.withinReach(month: month, year: near, lifetime: far, unitSystem: .imperial)
                == "656 ft short of your yearly furthest up")
        #expect(RecordCaption.withinReach(month: month, year: far, lifetime: far, unitSystem: .imperial) == nil)
    }
}
