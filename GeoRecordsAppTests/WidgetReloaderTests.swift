//
//  WidgetReloaderTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
import CoreData
@testable import GeoRecords

struct WidgetReloaderTests {

    /// Poll instead of a fixed sleep for the positive checks: the release workflow
    /// runs these on shared CI runners where a slow scheduler would turn a fixed
    /// 200 ms wait into a flaky failure
    @MainActor
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // Record and region saves never reloaded the widgets (only map generation
    // at launch did). Saves come in bursts (imports, border crossings), so the
    // reload is coalesced.
    @MainActor
    @Test func widgetReloaderCoalescesBurstsIntoOneReload() async throws {
        var reloads = 0
        let reloader = WidgetReloader(delay: .milliseconds(50)) { reloads += 1 }

        for _ in 0..<5 { reloader.requestReload() }
        try await waitUntil { reloads >= 1 }
        // Generous settle time: a burst must never produce a second reload
        try await Task.sleep(for: .milliseconds(300))
        #expect(reloads == 1)

        reloader.requestReload()
        try await waitUntil { reloads >= 2 }
        #expect(reloads == 2)
    }

    // Every record/region write goes through a context save, so one observer
    // covers them all — but the per-day extremes are RecordHistoryEntry rows
    // with the "Daily" timeframe, saved on every location fix, and the widgets
    // never show them, so those saves must not trigger reloads
    @MainActor
    @Test func widgetReloaderReactsOnlyToRecordRowSaves() async throws {
        let model = PersistenceController.shared.container.managedObjectModel
        let container = NSPersistentContainer(name: "GeoRecordsModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)
        let context = container.viewContext

        var reloads = 0
        let reloader = WidgetReloader(delay: .milliseconds(50)) { reloads += 1 }
        reloader.observeSaves(of: context)

        let entry = RecordHistoryEntry(context: context)
        entry.id = UUID()
        entry.recordType = "Furthest North"
        entry.timeFrame = "Lifetime"
        entry.value = 60
        entry.timestamp = Date()
        try context.save()
        try await waitUntil { reloads >= 1 }
        #expect(reloads == 1)

        let daily = RecordHistoryEntry(context: context)
        daily.id = UUID()
        daily.recordType = "Furthest North"
        daily.timeFrame = TimeFrame.daily.rawValue
        daily.value = 61
        daily.timestamp = Date()
        try context.save()
        // Generous settle time: a Daily-row save must never trigger a reload
        try await Task.sleep(for: .milliseconds(300))
        #expect(reloads == 1)
    }
}
