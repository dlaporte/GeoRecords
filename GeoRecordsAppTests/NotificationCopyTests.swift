//
//  NotificationCopyTests.swift
//  GeoRecordsTests
//

import Testing
@testable import GeoRecords

struct NotificationCopyTests {

    // The body was "(69.6492°)": the place is in hand, so say it
    @Test func recordBodyNamesThePlaceWhenKnown() async throws {
        #expect(RecordManager.recordNotificationBody(value: "69.6492° N", locationName: "Tromsø, Norway") == "69.6492° N at Tromsø, Norway")
        #expect(RecordManager.recordNotificationBody(value: "69.6492° N", locationName: nil) == "69.6492° N")
        #expect(RecordManager.recordNotificationBody(value: "69.6492° N", locationName: "") == "69.6492° N")
        #expect(RecordManager.recordNotificationBody(value: "69.6492° N", locationName: unknownLocationString) == "69.6492° N")
    }

    @Test func regionBodyCarriesTheRunningCount() async throws {
        #expect(RegionTrackingManager.newRegionBody(name: "Nevada", count: 15, total: 50, kind: "states")
                == "Welcome to Nevada. That's 15 of 50 states.")
        #expect(RegionTrackingManager.newRegionBody(name: "Japan", count: 12, total: 195, kind: "countries")
                == "Welcome to Japan. That's 12 of 195 countries.")
        #expect(RegionTrackingManager.newRegionBody(name: "Asia", count: 1, total: 7, kind: "continents")
                == "Welcome to Asia. That's 1 of 7 continents.")
    }
}
