//
//  NeverRecordCleanupTests.swift
//  GeoRecordsTests
//

import Testing
import CoreData
import CoreLocation
@testable import GeoRecords

// Rows written against an empty or stale in-memory slot never held the record of
// their period. The startup cleanup deletes them (automatic sources only), and
// new fixes and photos now compete against Core Data's best for their own period
// when the slot can't answer.
@MainActor
struct NeverRecordCleanupTests {

    private func remaining(_ ctx: NSManagedObjectContext) throws -> [(String, String, Double)] {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        return try ctx.fetch(request).map { ($0.recordType ?? "", $0.timeFrame ?? "", $0.value) }
    }

    @Test func rowsThatNeverBeatTheirPeriodsBestAreFound() async throws {
        let ctx = try makeInMemoryContext()
        // Lifetime: the 2022 record stands; the two post-restore rows never beat it
        insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 66.0, lat: 66, lon: 10, timestamp: noon(2022, 6, 3), source: nil)
        let bogusNorth = insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 42.47, lat: 42.47, lon: -70.9, timestamp: noon(2026, 8, 10))
        // A wizard choice may be less extreme on purpose: kept
        insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 60.0, lat: 60, lon: 10, timestamp: noon(2026, 9, 1), source: "wizard")
        // Lower-is-better types: the 2001 record stands
        insertRow(ctx, type: "Furthest South", timeFrame: "Lifetime", value: -17.68, lat: -17.68, lon: -70, timestamp: noon(2001, 10, 10), source: nil)
        let bogusSouth = insertRow(ctx, type: "Furthest South", timeFrame: "Lifetime", value: 42.47, lat: 42.47, lon: -70.9, timestamp: noon(2026, 8, 10))
        // Yearly: January's 481 stands for 2026; March's 153 never held the year; 2027 starts fresh
        insertRow(ctx, type: "Furthest Up", timeFrame: "Yearly", value: 481.2, lat: 43, lon: -72, timestamp: noon(2026, 1, 30))
        let bogusYear = insertRow(ctx, type: "Furthest Up", timeFrame: "Yearly", value: 153.2, lat: 43, lon: -72, timestamp: noon(2026, 3, 1))
        insertRow(ctx, type: "Furthest Up", timeFrame: "Yearly", value: 100.0, lat: 43, lon: -72, timestamp: noon(2027, 1, 5))
        // Monthly: an October photo added later outranks the live rows after it; November starts fresh
        insertRow(ctx, type: "Furthest from Home", timeFrame: "Monthly", value: 14330.9, lat: 42.6, lon: -70.9, timestamp: noon(2026, 10, 1), source: "photo", dateAdded: noon(2026, 10, 2))
        let bogusMonth = insertRow(ctx, type: "Furthest from Home", timeFrame: "Monthly", value: 3330.6, lat: 42.5, lon: -70.9, timestamp: noon(2026, 10, 1).addingTimeInterval(3600))
        insertRow(ctx, type: "Furthest from Home", timeFrame: "Monthly", value: 500.0, lat: 42.5, lon: -70.9, timestamp: noon(2026, 11, 1))
        // An exact duplicate written by a second pass in the same second
        insertRow(ctx, type: "Furthest East", timeFrame: "Lifetime", value: 139.69, lat: 35, lon: 139.69, timestamp: noon(2007, 10, 26), source: nil)
        let bogusDuplicate = insertRow(ctx, type: "Furthest East", timeFrame: "Lifetime", value: 139.69, lat: 35, lon: 139.69, timestamp: noon(2007, 10, 26))
        // Legacy rows without a source are kept even when less extreme
        insertRow(ctx, type: "Furthest West", timeFrame: "Yearly", value: -90.0857, lat: 30, lon: -90.0857, timestamp: noon(2019, 1, 10), source: nil)
        insertRow(ctx, type: "Furthest West", timeFrame: "Yearly", value: -90.0855, lat: 30, lon: -90.0855, timestamp: noon(2019, 2, 21), source: nil)
        // Daily rows and region rows are never touched
        insertRow(ctx, type: "Furthest Up", timeFrame: "Daily", value: 1, lat: 43, lon: -72, timestamp: noon(2026, 3, 2))
        insertRow(ctx, type: "New Country", timeFrame: "Lifetime", value: 1, lat: 48.8, lon: 2.3, timestamp: noon(2026, 8, 10), regionCode: "FR")

        let found = RecordHistoryManager.rowsThatNeverHeldTheRecord(in: ctx)
        #expect(Set(found.map(\.objectID)) == Set([bogusNorth, bogusSouth, bogusYear, bogusMonth, bogusDuplicate].map(\.objectID)))
    }

    @Test func cleanupDeletesOnlyThoseRows() async throws {
        let ctx = try makeInMemoryContext()
        insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 66.0, lat: 66, lon: 10, timestamp: noon(2022, 6, 3), source: nil)
        insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 42.47, lat: 42.47, lon: -70.9, timestamp: noon(2026, 8, 10))
        insertRow(ctx, type: "Furthest North", timeFrame: "Monthly", value: 42.47, lat: 42.47, lon: -70.9, timestamp: noon(2026, 8, 10))

        let rows = RecordHistoryManager.rowsThatNeverHeldTheRecord(in: ctx)
        #expect(rows.count == 1)
        rows.forEach(ctx.delete)
        try ctx.save()
        #expect(try remaining(ctx).map(\.2) == [66.0, 42.47])
        #expect(RecordHistoryManager.rowsThatNeverHeldTheRecord(in: ctx).isEmpty)
    }

    @Test func bestRecordOfAPeriodComesFromCoreData() async throws {
        let ctx = try makeInMemoryContext()
        insertRow(ctx, type: "Furthest North", timeFrame: "All-Time", value: 66.0, lat: 66, lon: 10, timestamp: noon(2022, 6, 3))
        insertRow(ctx, type: "Furthest North", timeFrame: "Lifetime", value: 60.0, lat: 60, lon: 10, timestamp: noon(2024, 6, 3))
        insertRow(ctx, type: "Furthest North", timeFrame: "Yearly", value: 50.0, lat: 50, lon: 10, timestamp: noon(2026, 2, 1))
        insertRow(ctx, type: "Furthest North", timeFrame: "Yearly", value: 55.0, lat: 55, lon: 10, timestamp: noon(2025, 2, 1))
        insertRow(ctx, type: "Furthest North", timeFrame: "Monthly", value: 45.0, lat: 45, lon: 10, timestamp: noon(2026, 8, 5))
        insertRow(ctx, type: "Furthest South", timeFrame: "Monthly", value: 40.0, lat: 40, lon: 10, timestamp: noon(2026, 8, 5))
        insertRow(ctx, type: "Furthest South", timeFrame: "Monthly", value: 38.0, lat: 38, lon: 10, timestamp: noon(2026, 8, 6))

        let around = noon(2026, 8, 20)
        #expect(RecordHistoryManager.bestRecord(type: "Furthest North", timeFrame: .allTime, around: around, in: ctx)?.value == 66.0)
        #expect(RecordHistoryManager.bestRecord(type: "Furthest North", timeFrame: .year, around: around, in: ctx)?.value == 50.0)
        #expect(RecordHistoryManager.bestRecord(type: "Furthest North", timeFrame: .month, around: around, in: ctx)?.value == 45.0)
        #expect(RecordHistoryManager.bestRecord(type: "Furthest South", timeFrame: .month, around: around, in: ctx)?.value == 38.0)
        #expect(RecordHistoryManager.bestRecord(type: "Furthest North", timeFrame: .month, around: noon(2026, 9, 1), in: ctx) == nil)
        #expect(RecordHistoryManager.bestRecord(type: "Furthest North", timeFrame: .daily, around: around, in: ctx) == nil)
    }

    @Test func aFixBelongsToItsOwnPeriod() async throws {
        let now = noon(2026, 11, 2)
        #expect(TimeFrame.month.isCurrentPeriod(for: noon(2026, 11, 1), now: now))
        #expect(!TimeFrame.month.isCurrentPeriod(for: noon(2026, 10, 31), now: now))
        #expect(TimeFrame.year.isCurrentPeriod(for: noon(2026, 1, 1), now: now))
        #expect(!TimeFrame.year.isCurrentPeriod(for: noon(2025, 12, 31), now: now))
        #expect(TimeFrame.allTime.isCurrentPeriod(for: noon(2001, 1, 1), now: now))
        #expect(TimeFrame.daily.isCurrentPeriod(for: noon(2001, 1, 1), now: now))
    }
}
