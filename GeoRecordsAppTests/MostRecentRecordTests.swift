//
//  MostRecentRecordTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

@MainActor
struct MostRecentRecordTests {

    // The Lock Screen's "most recent" is the row added last (a backfilled 2015 photo
    // record added today counts as most recent), never a Daily or at-home row
    @Test func mostRecentPicksByDateAddedAndSkipsHiddenRows() async throws {
        let ctx = try makeInMemoryContext()
        let home = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
        insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 70, lat: 70, lon: 10,
                  timestamp: noon(2026, 10, 10), dateAdded: noon(2026, 10, 10))
        let backfilled = insertRow(ctx, type: "New State", timeFrame: "Lifetime", value: 1, lat: 36, lon: -115,
                                   timestamp: noon(2015, 6, 1), dateAdded: noon(2026, 10, 20), regionCode: "US-NV")
        insertRow(ctx, type: "Furthest Up", timeFrame: "Daily", value: 900, lat: 46.8, lon: -121.7,
                  timestamp: noon(2026, 10, 25), dateAdded: noon(2026, 10, 25))
        insertRow(ctx, type: "Furthest East", timeFrame: "Monthly", value: -122.3, lat: 47.6, lon: -122.3,
                  timestamp: noon(2026, 10, 26), dateAdded: noon(2026, 10, 26))  // at home
        let rows = try ctx.fetch(RecordHistoryEntry.fetchRequest())
        let picked = try #require(mostRecentlyAddedRecord(rows: rows, home: home))
        #expect(picked.objectID == backfilled.objectID)
    }

    @Test func mostRecentFallsBackToTimestampWithoutDateAdded() async throws {
        let ctx = try makeInMemoryContext()
        let older = insertRow(ctx, type: "Furthest North", timeFrame: "Yearly", value: 60, lat: 60, lon: 10, timestamp: noon(2026, 9, 1))
        older.dateAdded = nil
        let newer = insertRow(ctx, type: "Furthest South", timeFrame: "Yearly", value: 30, lat: 30, lon: 10, timestamp: noon(2026, 10, 1))
        newer.dateAdded = nil
        let rows = try ctx.fetch(RecordHistoryEntry.fetchRequest())
        #expect(mostRecentlyAddedRecord(rows: rows, home: nil)?.objectID == newer.objectID)
    }
}
