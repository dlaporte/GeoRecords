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
}
