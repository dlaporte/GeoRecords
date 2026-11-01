//
//  WidgetReloaderTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
import CoreData
@testable import GeoRecords

struct WidgetReloaderTests {

    // Record and region saves never reloaded the widgets (only map generation
    // at launch did). Saves come in bursts (imports, border crossings), so the
    // reload is coalesced.
    @MainActor
    @Test func widgetReloaderCoalescesBurstsIntoOneReload() async throws {
        var reloads = 0
        let reloader = WidgetReloader(delay: .milliseconds(50)) { reloads += 1 }

        for _ in 0..<5 { reloader.requestReload() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(reloads == 1)

        reloader.requestReload()
        try await Task.sleep(for: .milliseconds(200))
        #expect(reloads == 2)
    }

    // Every record/region write goes through a context save, so one observer
    // covers them all — but daily-stat rows are saved on every location fix
    // and the widgets don't show them, so those must not trigger reloads
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
        try await Task.sleep(for: .milliseconds(200))
        #expect(reloads == 1)

        let stat = DailyStatistic(context: context)
        stat.id = UUID()
        stat.date = Date()
        stat.maxNorth = 60
        try context.save()
        try await Task.sleep(for: .milliseconds(200))
        #expect(reloads == 1)
    }
}
