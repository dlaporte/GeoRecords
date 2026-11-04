//
//  StatsGridRenderTests.swift
//  GeoRecordsTests
//
//  Renders the Stats card grid at the widths where cards tile (the iPhone Duo inner
//  display in landscape, an iPad in landscape) with numbered placeholder cards, and
//  attaches the PNGs. This is the one test that drives SwiftUI's real proposal
//  sequence through the Layout (zero, unspecified and infinite probes included).
//  Expected: five cards at 868 pt → rows of 2, 2 and one full-width card; at
//  1194 pt → a row of 3 then two half-width cards; six at 868 pt → three rows of 2.
//

import XCTest
import SwiftUI
@testable import GeoRecords

@MainActor
final class StatsGridRenderTests: XCTestCase {

    func testFiveCardsAtDuoLandscapeAndPadLandscapeWidths() {
        attach(page(cards: 5), size: CGSize(width: 868, height: 600), name: "stats-grid-5-duo-landscape")
        attach(page(cards: 5), size: CGSize(width: 1194, height: 600), name: "stats-grid-5-pad-landscape")
    }

    func testSixCardsFillThreeRowsAtDuoLandscapeWidth() {
        attach(page(cards: 6), size: CGSize(width: 868, height: 600), name: "stats-grid-6-duo-landscape")
    }

    /// Home not set: the Distance builder yields no cards, so Elevation and Regions
    /// (4 and 5) share one row at half width
    func testFirstGroupSkippedLeavesTwoHalfWidthCards() {
        attach(page(cards: 5, firstGroup: false), size: CGSize(width: 1194, height: 400), name: "stats-grid-2-pad-landscape")
    }

    /// The grid as Stats hosts it: in a scroll view's stack
    private func page(cards: Int, firstGroup: Bool = true) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                FlowingCardGrid {
                    sampleCards(count: cards, firstGroup: firstGroup)
                }
            }
            .padding(.vertical)
        }
    }

    /// Cards behind the same `Group` and `if` shapes the Stats body uses, so the
    /// Layout must see one subview per card; the second is taller, as the
    /// bidirectional charts are
    @ViewBuilder
    private func sampleCards(count: Int, firstGroup: Bool) -> some View {
        if firstGroup {
            Group {
                card(1, .blue, height: 120)
                card(2, .orange, height: 160)
                card(3, .red, height: 120)
            }
        }
        if count > 3 { card(4, .green, height: 120) }
        if count > 4 { card(5, .purple, height: 140) }
        if count > 5 { card(6, .teal, height: 120) }
    }

    private func card(_ number: Int, _ color: Color, height: CGFloat) -> some View {
        Text("\(number)")
            .font(.largeTitle.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 12).fill(color))
            .padding(.horizontal)
    }
}
