//
//  ImportWizardTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

struct ImportWizardTests {

    // Toggling an existing record off in the wizard deletes it on import; the
    // confirmation must name exactly what goes
    @Test func wizardRemovalSummaryNamesEachRecordAndPeriod() async throws {
        let deletions = [
            RecordToDelete(recordType: "Furthest North", timeFrame: .allTime, year: nil, month: nil),
            RecordToDelete(recordType: "Furthest Up", timeFrame: .year, year: 2024, month: nil),
            RecordToDelete(recordType: "Furthest East", timeFrame: .month, year: 2025, month: 3)
        ]
        #expect(PhotoLibraryScanner.removalSummary(for: deletions)
                == ["Furthest North (Lifetime)", "Furthest Up (2024)", "Furthest East (Mar 2025)"])
    }
}
