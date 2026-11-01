//
//  UXReviewFixTests.swift
//  GeoRecordsTests
//
//  Regression tests for the bugs found in the November 2026 UX review
//  (docs/UX_REVIEW_2026-11.md). Each test names the user-visible symptom.
//

import Testing
import Foundation
@testable import GeoRecords

struct UXReviewFixTests {

    // MARK: - Siri phrasing

    // "You don't have a this month's Furthest North record yet." read badly;
    // the timeframe qualifier has to move to where English puts it.
    @Test func siriMissingRecordDialogReadsNaturally() async throws {
        #expect(GetRecordIntent.missingRecordDialog(timeFrame: .month, typeName: "Furthest North")
                == "You don't have a Furthest North record for this month yet.")
        #expect(GetRecordIntent.missingRecordDialog(timeFrame: .year, typeName: "Furthest Up")
                == "You don't have a Furthest Up record for this year yet.")
        #expect(GetRecordIntent.missingRecordDialog(timeFrame: .lifetime, typeName: "Furthest South")
                == "You don't have a lifetime Furthest South record yet.")
    }

    @Test func siriRecordDialogDropsEmptyLocationName() async throws {
        // Geocoding can store "" while throttled; that must not read as "at , set"
        #expect(GetRecordIntent.recordDialog(timeFrame: .year, typeName: "Furthest Up",
                                             value: "3,200 ft", locationName: "", date: "Oct 12, 2026")
                == "Your Furthest Up record for this year is 3,200 ft, set Oct 12, 2026.")
        #expect(GetRecordIntent.recordDialog(timeFrame: .lifetime, typeName: "Furthest North",
                                             value: "69.6492°", locationName: "Tromsø", date: "Jun 3, 2024")
                == "Your lifetime Furthest North record is 69.6492° at Tromsø, set Jun 3, 2024.")
        #expect(GetRecordIntent.recordDialog(timeFrame: .month, typeName: "Furthest East",
                                             value: "-71.0589°", locationName: nil, date: "Nov 1, 2026")
                == "Your Furthest East record for this month is -71.0589°, set Nov 1, 2026.")
    }

    // MARK: - Timeframe pulldowns

    // The picker already prepends "This Year" / "This Month", so the history
    // lists must not contain the current period too (it showed twice).
    @Test func pulldownYearListExcludesCurrentYear() async throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(TimeFramePickerWithBadges.pastYears([2026, 2025, 2024], now: now) == [2025, 2024])
        // A user whose only data is this year gets no history menu at all
        #expect(TimeFramePickerWithBadges.pastYears([2026], now: now).isEmpty)
    }

    @Test func pulldownMonthListExcludesCurrentMonth() async throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let months = [
            MonthSelection(year: 2026, month: 11),
            MonthSelection(year: 2026, month: 10),
            MonthSelection(year: 2025, month: 11)
        ]
        #expect(TimeFramePickerWithBadges.pastMonths(months, now: now)
                == [MonthSelection(year: 2026, month: 10), MonthSelection(year: 2025, month: 11)])
    }

    // MARK: - Backup import alert

    // Every import path used "Import Complete" as the alert title even when the
    // message said the import failed
    @Test func importAlertTitleMatchesOutcome() async throws {
        #expect(BackupManager.importAlertTitle(succeeded: true) == "Import Complete")
        #expect(BackupManager.importAlertTitle(succeeded: false) == "Import Failed")
    }

    // MARK: - Inactivity reminder copy

    // The reminder is rescheduled when the app comes to the foreground, so it
    // measures days since the app was opened, not days without a location fix.
    // The body must say what it actually measures.
    @Test func inactivityReminderCopyDescribesWhatItMeasures() async throws {
        let body = LocationManager.inactivityReminderBody(days: 7)
        #expect(body.contains("opened GeoRecords in 7 days"))
        #expect(!body.contains("tracked"))
    }
}
