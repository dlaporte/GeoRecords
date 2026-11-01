//
//  HomeChangePromptTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

struct HomeChangePromptTests {
    let seattle = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
    let portland = CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784)

    @Test func offersOnlyForARealMoveWithRecordsToRewrite() async throws {
        #expect(HomeChangePrompt.shouldOffer(oldHome: nil, newHome: portland, fromHomeRowCount: 10) == false)
        #expect(HomeChangePrompt.shouldOffer(oldHome: seattle, newHome: portland, fromHomeRowCount: 0) == false)
        let nudge = CLLocationCoordinate2D(latitude: 47.6065, longitude: -122.3321)  // ~33 m
        #expect(HomeChangePrompt.shouldOffer(oldHome: seattle, newHome: nudge, fromHomeRowCount: 10) == false)
        #expect(HomeChangePrompt.shouldOffer(oldHome: seattle, newHome: portland, fromHomeRowCount: 10) == true)
    }

    @Test func messageSaysHowFarHomeMoved() async throws {
        let text = HomeChangePrompt.message(movedMeters: 5_000, unitSystem: .imperial)
        #expect(text.hasPrefix("Home moved 3.1 mi."))
        #expect(text.contains("Furthest from Home"))
    }

    @Test func snapshotReasonForHomeChangeHasALabel() async throws {
        let reason = try #require(BackupManager.snapshotReason(fromFileName: "Safety_home-change_GeoRecords_Backup_2026-11-01.georecords"))
        #expect(reason == "home-change")
        let snapshot = BackupManager.SafetySnapshot(url: URL(fileURLWithPath: "/tmp/x"), reason: reason, exportDate: .now,
                                                    recordCount: 1, regionCount: 0, deviceName: "test")
        #expect(snapshot.reasonLabel == "Before recalculating from-home records")
    }
}
