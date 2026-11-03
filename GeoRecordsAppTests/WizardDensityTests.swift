//
//  WizardDensityTests.swift
//  GeoRecordsTests
//

import Testing
import SwiftUI
@testable import GeoRecords

// The setup wizard's pages are fixed height; on the folded iPhone Duo (382×644
// window, about 486 pt per page) the roomy layout truncated every second line
// with "…". Roomy keeps today's literals; compact is the table that fits the Duo.
struct WizardDensityTests {

    @Test func roomyKeepsTodaysLiterals() async throws {
        let d = WizardDensity.roomy
        #expect(d.horizontalPadding == 40)
        #expect(d.stackSpacing == 30)
        #expect(d.titleSpacing == 12)
        #expect(d.listSpacing == 16)
        #expect(d.listTopPadding == 20)
        #expect(d.heroIconSize == 120)
        #expect(d.symbolSize == 60)
        #expect(d.welcomeTitleSize == 32)
        #expect(d.cardPadding == 20)
        #expect(d.cardIconWidth == 50)
        #expect(d.homeMapHeight == 200)
    }

    @Test func compactFitsTheFoldedDuo() async throws {
        let d = WizardDensity.compact
        #expect(d.horizontalPadding == 24)
        #expect(d.stackSpacing == 20)
        #expect(d.titleSpacing == 8)
        #expect(d.listSpacing == 12)
        #expect(d.listTopPadding == 12)
        #expect(d.heroIconSize == 88)
        #expect(d.symbolSize == 48)
        #expect(d.welcomeTitleSize == 28)
        #expect(d.cardPadding == 16)
        #expect(d.cardIconWidth == 36)
        #expect(d.homeMapHeight == 160)
    }

    @Test func roomyIsTheDefaultDensity() async throws {
        #expect(EnvironmentValues().wizardDensity == .roomy)
    }
}
