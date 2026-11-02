//
//  RecordHistoryQueriesTests.swift
//  GeoRecordsTests
//

import Testing
import CoreData
import CoreLocation
@testable import GeoRecords

@MainActor
struct RecordHistoryQueriesTests {

    // A year-slot record competes with Yearly AND Monthly rows of its year, exactly
    // as loadRecordsFromHistory fills the slot; other years never count
    @Test func previousRecordIsTheLatestLessExtremeRowInTheSlotsPeriod() async throws {
        let ctx = try makeInMemoryContext()
        insertRow(ctx, type: "Furthest North", timeFrame: "Yearly", value: 58, lat: 58, lon: 10, timestamp: noon(2024, 3, 1))
        insertRow(ctx, type: "Furthest North", timeFrame: "Monthly", value: 60, lat: 60, lon: 10, timestamp: noon(2024, 5, 1))
        insertRow(ctx, type: "Furthest North", timeFrame: "Yearly", value: 62, lat: 62, lon: 10, timestamp: noon(2023, 8, 1))
        let currentRow = insertRow(ctx, type: "Furthest North", timeFrame: "Yearly", value: 65, lat: 65, lon: 10, timestamp: noon(2024, 7, 1))
        var current = try #require(RecordDetail(from: currentRow))
        current.timeFrame = .year
        let previous = try #require(RecordHistoryManager.previousRecord(before: current, home: nil, in: ctx))
        #expect(previous.value == 60)
    }

    // One event writes a row per timeframe with the same timestamp; those siblings
    // are not "previous" records, and a more extreme older row means no progression
    @Test func previousRecordSkipsSiblingsAndMoreExtremeRows() async throws {
        let ctx = try makeInMemoryContext()
        let t = noon(2026, 10, 10)
        insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 70, lat: 70, lon: 10, timestamp: t)
        insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 72, lat: 72, lon: 10, timestamp: noon(2025, 1, 1))
        let row = insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 70, lat: 70, lon: 10, timestamp: t)
        let current = try #require(RecordDetail(from: row))
        #expect(RecordHistoryManager.previousRecord(before: current, home: nil, in: ctx) == nil)
    }

    @Test func previousRecordIgnoresRowsAtHome() async throws {
        let ctx = try makeInMemoryContext()
        let home = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
        insertRow(ctx, type: "Furthest Up", timeFrame: "Lifetime", value: 50, lat: 47.6, lon: -122.3, timestamp: noon(2026, 1, 1))
        insertRow(ctx, type: "Furthest Up", timeFrame: "Lifetime", value: 400, lat: 46.8, lon: -121.7, timestamp: noon(2026, 2, 1), locationName: "Paradise")
        let row = insertRow(ctx, type: "Furthest Up", timeFrame: "Lifetime", value: 1_200, lat: 46.85, lon: -121.76, timestamp: noon(2026, 8, 1))
        let current = try #require(RecordDetail(from: row))
        let previous = try #require(RecordHistoryManager.previousRecord(before: current, home: home, in: ctx))
        #expect(previous.locationName == "Paradise")
    }

    // "Records set" is one event per type and second: never Daily rows, never
    // region rows, never rows at home, and siblings collapse to one
    @Test func recordEventsCountOneEventPerTypeAndSecond() async throws {
        let ctx = try makeInMemoryContext()
        let t = noon(2026, 10, 10)
        for tf in ["Monthly", "Yearly", "Lifetime"] {
            insertRow(ctx, type: "Furthest North", timeFrame: tf, value: 70, lat: 70, lon: 10, timestamp: t)
        }
        insertRow(ctx, type: "Furthest North", timeFrame: "Daily", value: 70, lat: 70, lon: 10, timestamp: t)
        insertRow(ctx, type: "Furthest Up", timeFrame: "Monthly", value: 500, lat: 47.7, lon: -122.3, timestamp: noon(2026, 10, 12))
        insertRow(ctx, type: "New State", timeFrame: "Lifetime", value: 1, lat: 40, lon: -100, timestamp: noon(2026, 10, 13))
        insertRow(ctx, type: "Furthest East", timeFrame: "Monthly", value: -122.3, lat: 47.6, lon: -122.3, timestamp: noon(2026, 10, 14))
        insertRow(ctx, type: "Furthest West", timeFrame: "Monthly", value: -124, lat: 48, lon: -124, timestamp: noon(2026, 9, 30))
        let home = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
        let interval = DateInterval(start: noon(2026, 10, 1), end: noon(2026, 11, 1))
        let events = RecordHistoryManager.recordEvents(in: interval, home: home, in: ctx)
        #expect(events.count == 2)
        #expect(Set(events.map(\.recordType)) == [.north, .up])
        // The collapsed event carries the largest timeframe its rows set
        #expect(events.first { $0.recordType == .north }?.timeFrame == .allTime)
        #expect(events.first { $0.recordType == .up }?.timeFrame == .month)
    }

    // Older stores spell lifetime rows "All-Time" / "All Time"; a Yearly sibling
    // never outranks them
    @Test func recordEventsReadLegacyLifetimeSpellings() async throws {
        let ctx = try makeInMemoryContext()
        let t = noon(2026, 10, 10)
        insertRow(ctx, type: "Furthest South", timeFrame: "Yearly", value: 30, lat: 30, lon: 10, timestamp: t)
        insertRow(ctx, type: "Furthest South", timeFrame: "All-Time", value: 30, lat: 30, lon: 10, timestamp: t)
        insertRow(ctx, type: "Furthest West", timeFrame: "All Time", value: -100, lat: 40, lon: -100, timestamp: noon(2026, 10, 11))
        let interval = DateInterval(start: noon(2026, 10, 1), end: noon(2026, 11, 1))
        let events = RecordHistoryManager.recordEvents(in: interval, home: nil, in: ctx)
        #expect(events.map(\.timeFrame) == [.allTime, .allTime])
    }

    @Test func recalculateRewritesFromHomeValuesFromStoredCoordinates() async throws {
        let ctx = try makeInMemoryContext()
        let row = insertRow(ctx, type: "Furthest from Home", timeFrame: "Lifetime", value: 1, lat: 48.6, lon: -122.3, timestamp: noon(2026, 1, 1))
        let daily = insertRow(ctx, type: "Furthest from Home", timeFrame: "Daily", value: 1, lat: 48.1, lon: -122.3, timestamp: noon(2026, 1, 2))
        let north = insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 48.6, lat: 48.6, lon: -122.3, timestamp: noon(2026, 1, 1))
        let count = try RecordHistoryManager.recalculateFromHomeRecords(home: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3), in: ctx)
        #expect(count == 2)
        #expect(abs(row.value - 111_195) < 300)
        #expect(abs(daily.value - 55_597) < 300)
        #expect(north.value == 48.6)
    }
}
