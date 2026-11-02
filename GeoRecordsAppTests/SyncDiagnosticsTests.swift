//
//  SyncDiagnosticsTests.swift
//  GeoRecordsTests
//

import Testing
import CloudKit
@testable import GeoRecords

// "Failed to modify some records" is CloudKit's partial failure; the reasons live
// per item. Settings now shows them grouped by code so a TestFlight user can
// report what is actually failing
struct SyncDiagnosticsTests {

    private func partialFailure(_ items: [(String, CKError.Code)]) -> NSError {
        var byID: [CKRecord.ID: NSError] = [:]
        for (name, code) in items {
            byID[CKRecord.ID(recordName: name)] = NSError(domain: CKErrorDomain, code: code.rawValue,
                                                          userInfo: [NSLocalizedDescriptionKey: "desc \(code.rawValue)"])
        }
        return NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
                       userInfo: [CKPartialErrorsByItemIDKey: byID, NSLocalizedDescriptionKey: "Failed to modify some records"])
    }

    @Test func detailsGroupPartialErrorsByCode() async throws {
        let error = partialFailure([("rec-a", .serverRecordChanged), ("rec-b", .serverRecordChanged),
                                    ("rec-c", .assetFileNotFound), ("rec-d", .batchRequestFailed)])
        let lines = PersistenceController.syncErrorDetails(for: error)
        #expect(lines.first == "CloudKit partialFailure (2): Failed to modify some records")
        #expect(lines.contains { $0.hasPrefix("2 × serverRecordChanged (\(CKError.Code.serverRecordChanged.rawValue))") && $0.contains("rec-") })
        #expect(lines.contains { $0.hasPrefix("1 × assetFileNotFound (\(CKError.Code.assetFileNotFound.rawValue))") })
        #expect(lines.contains { $0.hasPrefix("1 × batchRequestFailed (\(CKError.Code.batchRequestFailed.rawValue))") })
        // Most frequent code first; the top-level line stays first
        #expect(lines[1].hasPrefix("2 ×"))
    }

    @Test func detailsForPlainErrorsAndNothing() async throws {
        let plain = NSError(domain: CKErrorDomain, code: CKError.Code.notAuthenticated.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        #expect(PersistenceController.syncErrorDetails(for: plain) == ["CloudKit notAuthenticated (\(CKError.Code.notAuthenticated.rawValue)): Not signed in"])
        let foreign = NSError(domain: "SomeDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        #expect(PersistenceController.syncErrorDetails(for: foreign) == ["SomeDomain 7: Boom"])
        #expect(PersistenceController.syncErrorDetails(for: nil).isEmpty)
    }

    @Test func guidanceCoversMoreBuriedCodes() async throws {
        let zoneGone = partialFailure([("rec-a", .userDeletedZone)])
        #expect(try #require(PersistenceController.syncErrorGuidance(for: zoneGone)).contains("iCloud copy"))
        let missingPhoto = partialFailure([("rec-a", .assetFileNotFound)])
        #expect(try #require(PersistenceController.syncErrorGuidance(for: missingPhoto)).contains("photo"))
        let tooLarge = partialFailure([("rec-a", .limitExceeded)])
        #expect(try #require(PersistenceController.syncErrorGuidance(for: tooLarge)).contains("too large"))
        let conflictsOnly = partialFailure([("rec-a", .serverRecordChanged), ("rec-b", .batchRequestFailed)])
        #expect(try #require(PersistenceController.syncErrorGuidance(for: conflictsOnly)).contains("newer copy"))
    }
}
