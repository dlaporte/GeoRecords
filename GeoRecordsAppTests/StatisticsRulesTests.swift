//
//  StatisticsRulesTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

struct StatisticsRulesTests {

    // The N/S and E/W summary rows took abs() of a signed distance, so a month
    // spent entirely north of home filled the "S" row with the least-northern
    // place. A row is only valid when the place is on that side of home.
    @Test func directionRowsOnlyShowPlacesOnTheirSideOfHome() async throws {
        // North record 312 mi north; south record 40 mi NORTH of home -> no S row
        let bothNorth = directionRowMagnitudes(positiveSigned: 312, negativeSigned: 40, threshold: 10)
        #expect(bothNorth.positive == 312)
        #expect(bothNorth.negative == nil)

        // Genuine pair -> both rows, as magnitudes
        let pair = directionRowMagnitudes(positiveSigned: 312, negativeSigned: -200, threshold: 10)
        #expect(pair.positive == 312 && pair.negative == 200)

        // Below threshold or missing -> dash
        let tiny = directionRowMagnitudes(positiveSigned: nil, negativeSigned: -5, threshold: 10)
        #expect(tiny.positive == nil && tiny.negative == nil)

        // Everything south of home -> only the S row
        let bothSouth = directionRowMagnitudes(positiveSigned: -50, negativeSigned: -200, threshold: 10)
        #expect(bothSouth.positive == nil && bothSouth.negative == 200)
    }

    // Tapping "This Month" on the 1st replaced the whole tab with the new-user
    // copy ("Start tracking your location...") for a user with years of data
    @Test func statsEmptyStateDistinguishesVeteransFromNewUsers() async throws {
        #expect(statsEmptyState(hasPeriodData: false, hasAnyData: false) == .firstRun)
        #expect(statsEmptyState(hasPeriodData: false, hasAnyData: true) == .emptyPeriod)
        #expect(statsEmptyState(hasPeriodData: true, hasAnyData: true) == nil)
    }
}
