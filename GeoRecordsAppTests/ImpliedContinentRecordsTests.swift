//
//  ImpliedContinentRecordsTests.swift
//  GeoRecordsTests
//

import Testing
import CoreData
import CoreLocation
@testable import GeoRecords

// Continents became geographic (continents.json). A one-shot pass adds the
// continent records that existing state and country records imply but lack,
// dated and sourced like the implying record. Nothing is deleted.
@MainActor
struct ImpliedContinentRecordsTests {

    private func continentRows(in context: NSManagedObjectContext) throws -> [RecordHistoryEntry] {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "recordType == %@", RecordType.continent.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        return try context.fetch(request)
    }

    private func insertRegion(_ context: NSManagedObjectContext, _ type: RecordType, code: String, name: String,
                              lat: Double, lon: Double, _ date: Date, source: String = "location") {
        insertRow(context, type: type.rawValue, timeFrame: TimeFrame.allTime.rawValue, value: date.timeIntervalSince1970,
                  lat: lat, lon: lon, timestamp: date, source: source, locationName: name, regionCode: code)
    }

    @Test func aVladivostokVisitImpliesAsia() async throws {
        let context = try makeInMemoryContext()
        insertRegion(context, .country, code: "RU", name: "Russia", lat: 48.48, lon: 135.07, noon(2023, 4, 10), source: "photo")
        insertRegion(context, .continent, code: "Europe", name: "Europe", lat: 48.86, lon: 2.35, noon(2022, 6, 1))

        #expect(RegionTrackingManager.addImpliedContinentRecords(in: context) == 1)

        let rows = try continentRows(in: context)
        #expect(rows.map(\.regionCode) == ["Europe", "Asia"])
        let asia = try #require(rows.last)
        #expect(asia.locationName == "Asia")
        #expect(asia.timestamp == noon(2023, 4, 10))
        #expect(asia.source == "photo")
        #expect(asia.latitude == 48.48 && asia.longitude == 135.07)

        // Running again adds nothing
        #expect(RegionTrackingManager.addImpliedContinentRecords(in: context) == 0)
        #expect(try continentRows(in: context).count == 2)
    }

    @Test func existingContinentsAreLeftAlone() async throws {
        let context = try makeInMemoryContext()
        insertRegion(context, .country, code: "RU", name: "Russia", lat: 55.75, lon: 37.62, noon(2021, 1, 1))
        insertRegion(context, .continent, code: "Europe", name: "Europe", lat: 55.75, lon: 37.62, noon(2021, 1, 1))

        #expect(RegionTrackingManager.addImpliedContinentRecords(in: context) == 0)
        #expect(try continentRows(in: context).count == 1)
    }

    @Test func statesAndCountriesImplyTheirContinents() async throws {
        let context = try makeInMemoryContext()
        insertRegion(context, .state, code: "US-WA", name: "Washington", lat: 47.61, lon: -122.33, noon(2019, 1, 1))
        insertRegion(context, .country, code: "JP", name: "Japan", lat: 35.68, lon: 139.65, noon(2023, 4, 10))
        insertRegion(context, .country, code: "GF", name: "French Guiana", lat: 4.93, lon: -52.33, noon(2024, 2, 2))
        // The earliest implying record dates the continent
        insertRegion(context, .country, code: "KR", name: "South Korea", lat: 37.57, lon: 126.98, noon(2024, 5, 5))

        #expect(RegionTrackingManager.addImpliedContinentRecords(in: context) == 3)
        let rows = try continentRows(in: context)
        #expect(rows.map(\.regionCode) == ["North America", "Asia", "South America"])
        #expect(rows.compactMap(\.timestamp) == [noon(2019, 1, 1), noon(2023, 4, 10), noon(2024, 2, 2)])
    }
}
