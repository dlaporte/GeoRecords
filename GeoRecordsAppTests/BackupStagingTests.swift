//
//  BackupStagingTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

struct BackupStagingTests {

    // Settings → Import Backup released the security scope before reading the
    // file; the staged copy must be made while the scope is held, and must
    // survive the original going away
    @Test func stagedBackupCopyOutlivesTheOriginal() async throws {
        let original = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-test-\(UUID().uuidString)")
            .appendingPathExtension("georecords")
        let payload = Data("{\"version\": 8}".utf8)
        try payload.write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }

        let staged = try BackupManager.stageImportedFile(from: original)
        defer { try? FileManager.default.removeItem(at: staged) }

        #expect(staged != original)
        #expect(staged.pathExtension == "georecords")
        try FileManager.default.removeItem(at: original)
        #expect(try Data(contentsOf: staged) == payload)
    }
}
