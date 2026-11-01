//
//  TestSupport.swift
//  GeoRecordsTests
//
//  Shared helpers: an in-memory Core Data context on the app's model, and a
//  one-line record-row inserter.
//

import Foundation
import CoreData
import CoreLocation
@testable import GeoRecords

/// An empty in-memory store using the app's managed object model
@MainActor
func makeInMemoryContext() throws -> NSManagedObjectContext {
    let model = PersistenceController.shared.container.managedObjectModel
    let container = NSPersistentContainer(name: "GeoRecordsModel", managedObjectModel: model)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    var loadError: Error?
    container.loadPersistentStores { _, error in loadError = error }
    if let loadError { throw loadError }
    return container.viewContext
}

@discardableResult
func insertRow(_ context: NSManagedObjectContext,
               type: String,
               timeFrame: String,
               value: Double,
               lat: Double,
               lon: Double,
               timestamp: Date,
               source: String? = "location",
               locationName: String? = nil,
               dateAdded: Date? = nil,
               regionCode: String? = nil) -> RecordHistoryEntry {
    let row = RecordHistoryEntry(context: context)
    row.id = UUID()
    row.recordType = type
    row.timeFrame = timeFrame
    row.value = value
    row.latitude = lat
    row.longitude = lon
    row.altitude = type == RecordType.up.rawValue ? value : 0
    row.timestamp = timestamp
    row.source = source
    row.locationName = locationName
    row.dateAdded = dateAdded ?? timestamp
    row.regionCode = regionCode
    try? context.save()
    return row
}

/// A date at noon local time, for period tests
func noon(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar = .current) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}
