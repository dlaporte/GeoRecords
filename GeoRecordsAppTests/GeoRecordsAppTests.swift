//
//  GeoRecordsTests.swift
//  GeoRecordsTests
//
//  Created by David LaPorte on 3/12/25.
//

import Testing
import CoreLocation
@testable import GeoRecords

struct GeoRecordsTests {

    // Regression: Greenland's overseas-territory bounding box contains all of Iceland
    // and much of northeastern Canada. Territory matching must confirm against real
    // polygons, or Reykjavík and Iqaluit get attributed to Greenland.
    @Test func territoryBoundingBoxesDoNotSwallowNeighbors() async throws {
        let service = RegionLookupService.shared

        let reykjavik = CLLocationCoordinate2D(latitude: 64.15, longitude: -21.94)
        #expect(service.region(for: reykjavik)?.code == "IS")

        let nuuk = CLLocationCoordinate2D(latitude: 64.18, longitude: -51.69)
        #expect(service.region(for: nuuk)?.code == "GL")

        let iqaluit = CLLocationCoordinate2D(latitude: 63.75, longitude: -68.51)
        #expect(service.region(for: iqaluit)?.code == "CA")
    }

    // With biggest-achievement-only notifications, exactly ONE notification is posted per
    // record type per location event, so the identifier is per-type: a later event's
    // notification replaces the earlier one instead of stacking up during a long drive.
    @Test func notificationIdentifierIsStablePerType() async throws {
        #expect(
            NotificationIdentifier.newRecord(type: "Furthest North")
                == NotificationIdentifier.newRecord(for: .north)
        )
        #expect(
            NotificationIdentifier.newRecord(for: .north)
                != NotificationIdentifier.newRecord(for: .south)
        )
    }

    // The single notification must carry the MOST significant timeframe beaten
    // (lifetime > yearly > monthly) — this is what makes a border crossing produce
    // one "lifetime" banner instead of three, while the deep link still lands on
    // the right tab for lesser events.
    @Test func mostSignificantTimeFramePicksBiggestAchievement() async throws {
        #expect(TimeFrame.mostSignificant(of: [.month, .year, .allTime]) == .allTime)
        #expect(TimeFrame.mostSignificant(of: [.month, .year]) == .year)
        #expect(TimeFrame.mostSignificant(of: [.month]) == .month)
        #expect(TimeFrame.mostSignificant(of: []) == nil)
    }

    // The notification payload carries TimeFrame.rawValue and widget URLs carry deepLinkParam;
    // both must parse back into the enum for tab selection to work.
    @Test func timeFrameParsingRoundTrips() async throws {
        for timeFrame in TimeFrame.allCases {
            #expect(TimeFrame(rawValue: timeFrame.rawValue) == timeFrame)
        }
        #expect(TimeFrame(deepLinkParam: "monthly") == .month)
        #expect(TimeFrame(deepLinkParam: "yearly") == .year)
        #expect(TimeFrame(deepLinkParam: "allTime") == .allTime)
        #expect(TimeFrame(deepLinkParam: "bogus") == nil)
    }

    // Selection semantics used by findBestRecord: the most extreme value wins in the
    // direction appropriate to the record type.
    @Test func shouldReplacePrefersMoreExtremeValues() async throws {
        #expect(RecordType.north.shouldReplace(newValue: 50.0, oldValue: 45.0))
        #expect(!RecordType.north.shouldReplace(newValue: 42.0, oldValue: 45.0))
        #expect(RecordType.south.shouldReplace(newValue: -10.0, oldValue: 5.0))
        #expect(!RecordType.west.shouldReplace(newValue: -60.0, oldValue: -71.0))
        #expect(RecordType.up.shouldReplace(newValue: 3000.0, oldValue: 1200.0))
    }

    // Safety snapshots are the user's escape hatch after a failed iCloud restore,
    // so the reason slug (which drives the restore UI's labels) must parse out of
    // the snapshot filename — including reasons that themselves contain underscores'
    // sibling separators like hyphens — and reject non-snapshot files.
    @Test func safetySnapshotReasonParsesFromFileName() async throws {
        #expect(
            BackupManager.snapshotReason(
                fromFileName: "Safety_local-reset_GeoRecords_Backup_2026-08-12_08-30-00.georecords"
            ) == "local-reset"
        )
        #expect(
            BackupManager.snapshotReason(
                fromFileName: "Safety_icloud-restore_GeoRecords_Backup_2026-08-12.georecords"
            ) == "icloud-restore"
        )
        // Regular exports and stray files are not snapshots
        #expect(BackupManager.snapshotReason(fromFileName: "GeoRecords_Backup_2026-08-12.georecords") == nil)
        #expect(BackupManager.snapshotReason(fromFileName: ".DS_Store") == nil)
    }

    // v8 backups carry embedded photoData (legacy records and photos attached via
    // the new-record prompt have no Photos-library asset to re-link — the JPEG in
    // the database is the only copy). It must survive a JSON round trip, and
    // pre-v8 files without the key must still decode.
    @Test func backupRecordRoundTripsPhotoDataAndDecodesLegacyFiles() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let record = BackupManager.BackupRecord(
            id: UUID().uuidString, recordType: "Furthest North", timeFrame: "Lifetime",
            value: 64.15, timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            latitude: 64.15, longitude: -21.94, altitude: 12,
            locationName: "Reykjavík", photoAssetIdentifier: nil, photoCloudIdentifier: nil,
            notes: nil, regionCode: "IS", source: "manual",
            dateAdded: Date(timeIntervalSince1970: 1_750_000_100), photoData: jpeg
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(BackupManager.BackupRecord.self, from: encoder.encode(record))
        #expect(decoded.photoData == jpeg)
        #expect(decoded.source == "manual")
        #expect(decoded.dateAdded == record.dateAdded)

        // A v7-era record (no photoData/source keys) still decodes, with nils
        let legacyJSON = """
        {"id": "\(UUID().uuidString)", "recordType": "Furthest Up", "timeFrame": "Monthly",
         "value": 3000, "timestamp": "2025-07-01T12:00:00Z",
         "latitude": 51.0, "longitude": -115.0, "altitude": 3000}
        """
        let legacy = try decoder.decode(BackupManager.BackupRecord.self, from: Data(legacyJSON.utf8))
        #expect(legacy.photoData == nil)
        #expect(legacy.source == nil)
    }

    @Test func uniqueRegionCountsMatchRegionsTabRules() async throws {
        // Duplicate rows (iCloud sync merges, home-migration churn) collapse to one;
        // bare and US-prefixed state codes are the same state
        let states: [(regionCode: String?, locationName: String?)] = [
            ("US-MA", "Massachusetts"), ("US-MA", "Massachusetts"), ("MA", "Massachusetts"),
            ("US-DC", "District of Columbia"),  // tracked, but not one of the 50
            (nil, "Mystery State"),             // no code: never counted as a state
            ("US-VT", "Vermont"),
        ]
        #expect(countUniqueRegions(states, type: .state) == 2)

        let countries: [(regionCode: String?, locationName: String?)] = [
            ("US", "United States"), ("US", "United States"), ("US", "United States"),
            ("GL", "Greenland"),   // territory: shown as a card but not counted
            ("FR", "France"),
            (nil, "Atlantis"),     // uncoded countries still count, keyed by name
        ]
        #expect(countUniqueRegions(countries, type: .country) == 3)

        let continents: [(regionCode: String?, locationName: String?)] = [
            ("North America", "North America"), ("North America", "North America"),
            ("North America", "North America"), ("Europe", "Europe"),
        ]
        #expect(countUniqueRegions(continents, type: .continent) == 2)
    }

    @Test func regionVisitTypesAreExemptFromAtHomeCleanup() async throws {
        // Home-region rows live at the home coordinate on purpose; the at-home
        // cleanup must never treat region visits as bogus data
        for type in RecordType.allCases {
            #expect(type.isRegionVisit == !type.isGeographicExtreme)
        }
        #expect(RecordType.state.isRegionVisit)
        #expect(RecordType.country.isRegionVisit)
        #expect(RecordType.continent.isRegionVisit)
        #expect(!RecordType.north.isRegionVisit)
        #expect(!RecordType.fromHome.isRegionVisit)
    }
}
