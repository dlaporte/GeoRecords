//
//  AdaptiveLayoutTests.swift
//  GeoRecordsTests
//

import Testing
import SwiftUI
@testable import GeoRecords

// Layout follows size classes, never the main screen: regular width means
// list-and-detail layouts (iPad, iPhone Duo open, Max phones in landscape);
// compact height means tighter cards (phones in landscape, Duo folded in landscape)
struct AdaptiveLayoutTests {

    @Test func widthComesFromTheHorizontalSizeClass() async throws {
        #expect(LayoutWidth(horizontal: .regular) == .regular)
        #expect(LayoutWidth(horizontal: .compact) == .compact)
        #expect(LayoutWidth(horizontal: nil) == .compact)
    }

    @Test func cardSizingComesFromTheVerticalSizeClass() async throws {
        #expect(CardSizing(vertical: .compact).isCompact)
        #expect(!CardSizing(vertical: .regular).isCompact)
        #expect(!CardSizing(vertical: nil).isCompact)
        #expect(CardSizing(vertical: .regular).iconSize == 44)
        #expect(CardSizing(vertical: .compact).iconSize == 32)
    }

    // The Duo's inner display upright (669 pt) is regular width but its split views
    // cannot tile: iOS draws the sidebar as a drawer over the detail. Under 720 pt the
    // phone layouts are used instead; the iPad mini (744) is the narrowest that tiles
    @Test func regularLayoutsNeedSevenHundredTwentyPoints() async throws {
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 669) == .compact)   // iPhone Duo inner display, upright
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 694) == .compact)   // iPad two-thirds Split View
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 719) == .compact)
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 720) == .regular)
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 744) == .regular)   // iPad mini portrait
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 834) == .regular)   // iPad Pro 11" portrait
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 868) == .regular)   // iPhone Duo inner display, landscape
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 1194) == .regular)  // iPad Pro 11" landscape
        #expect(LayoutWidth(horizontal: .regular, windowWidth: nil) == .regular)   // unmeasured: the size class alone
        #expect(LayoutWidth(horizontal: .compact, windowWidth: 1194) == .compact)  // a compact size class always wins
        #expect(LayoutWidth.minimumRegularWidth == 720)
        #expect(LayoutWidth(horizontal: .regular) == LayoutWidth(horizontal: .regular, windowWidth: nil))
    }

    // The Duo held upright and partially folded (the book pose): the system shows a
    // split view as two even pages along the fold, so the split layouts come back at
    // 669 pt; flat, the same width stays compact. The fold never helps a compact size class
    @Test func theFoldBringsTheSplitLayoutsBack() async throws {
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 669, foldDivided: true) == .regular)
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 669, foldDivided: false) == .compact)
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 868, foldDivided: false) == .regular)
        #expect(LayoutWidth(horizontal: .compact, windowWidth: 669, foldDivided: true) == .compact)
        #expect(LayoutWidth(horizontal: .regular, windowWidth: 669) == LayoutWidth(horizontal: .regular, windowWidth: 669, foldDivided: false))
    }

    // A detail column puts the photo beside the rows only where both fit: iPads in
    // landscape. iPad portrait, the Duo in landscape and a book-pose page stack them
    @Test func detailColumnsStackBelowSevenHundredTwentyPoints() async throws {
        #expect(DetailColumnStyle.style(forColumnWidth: 334) == .stacked)   // a Duo book-pose page
        #expect(DetailColumnStyle.style(forColumnWidth: 488) == .stacked)   // Duo landscape
        #expect(DetailColumnStyle.style(forColumnWidth: 652) == .stacked)   // iPad 13" portrait
        #expect(DetailColumnStyle.style(forColumnWidth: 719) == .stacked)
        #expect(DetailColumnStyle.style(forColumnWidth: 720) == .wide)
        #expect(DetailColumnStyle.style(forColumnWidth: 867) == .wide)      // iPad 11" landscape
        #expect(DetailColumnStyle.style(forColumnWidth: 996) == .wide)      // iPad 13" landscape
    }

    // Beside the rows the panel takes 40% and the map the rest; above them 60%; never
    // under 300 pt, which the Duo's short landscape column only just affords
    @Test func thePanelTakesItsShareOfTheColumn() async throws {
        #expect(DetailColumnStyle.panelHeight(forColumnHeight: 800, style: .wide) == 320)
        #expect(DetailColumnStyle.panelHeight(forColumnHeight: 673, style: .wide) == 300)      // 40% would be 269
        #expect(abs(DetailColumnStyle.panelHeight(forColumnHeight: 1144, style: .stacked) - 686.4) < 0.01)
        #expect(abs(DetailColumnStyle.panelHeight(forColumnHeight: 523, style: .stacked) - 313.8) < 0.01)
        #expect(DetailColumnStyle.panelHeight(forColumnHeight: 400, style: .stacked) == 300)   // 60% would be 240
        #expect(DetailColumnStyle.panelHeight(forColumnHeight: 200, style: .stacked) == 200)   // never more than there is
        #expect(DetailColumnStyle.minimumPanelHeight == 300)
    }

    // Share and delete lead only on the Duo in landscape (a hinged device, window under
    // 720 pt tall): the iPad's top tab bar owns the leading area, and the book pose is tall
    @Test func actionsLeadOnlyOnTheDuoInLandscape() async throws {
        #expect(DetailActionsPlacement.leading(hasHinge: true, windowHeight: 669))
        #expect(!DetailActionsPlacement.leading(hasHinge: true, windowHeight: 951))   // the book pose
        #expect(!DetailActionsPlacement.leading(hasHinge: false, windowHeight: 600))  // a Stage Manager window
        #expect(!DetailActionsPlacement.leading(hasHinge: false, windowHeight: 744))  // iPad mini landscape
        #expect(!DetailActionsPlacement.leading(hasHinge: true, windowHeight: nil))
    }

    // A place name breaks after its first comma where it would wrap
    @Test func placeNamesBreakAfterTheFirstComma() async throws {
        let polynesia = PlaceName.lines("French Polynesia, French Polynesia")
        #expect(polynesia?.first == "French Polynesia,")
        #expect(polynesia?.rest == "French Polynesia")
        let shinjuku = PlaceName.lines("Shinjuku, Tokyo, Japan")
        #expect(shinjuku?.first == "Shinjuku,")
        #expect(shinjuku?.rest == "Tokyo, Japan")
        #expect(PlaceName.lines("Tromsø") == nil)
        #expect(PlaceName.lines("Oops,") == nil)
        #expect(PlaceName.lines("Oops, ") == nil)
    }

    // Cards sit on the same 16 pt margin as the picker, map and detail rows
    @Test func cardsShareTheContentMargin() async throws {
        #expect(CardSizing(vertical: .regular).horizontalPadding == 16)
        #expect(CardSizing(vertical: .compact).horizontalPadding == 16)
    }

    @Test func statsCardsTileOnlyInRegularWidth() async throws {
        #expect(StatsGrid.columns(for: .compact).count == 1)
        let regular = StatsGrid.columns(for: .regular)
        #expect(regular.count == 1)
        if case .adaptive(let minimum, _) = regular[0].size {
            #expect(minimum == 360)
        } else {
            Issue.record("regular width should use an adaptive column")
        }
    }

    // Where the Stats cards tile they share one grid: rows of equal columns, as many as
    // fit at 360 pt (the LazyVGrid rule), so no section restarts a row and leaves a card alone
    @Test func flowingGridFitsAsManyColumnsAsTheAdaptiveGrid() async throws {
        let grid = FlowingCardGrid()
        #expect(grid.columnCount(for: 393) == 1)      // iPhone 16 Pro
        #expect(grid.columnCount(for: 669) == 1)      // iPhone Duo inner display, upright
        #expect(grid.columnCount(for: 694) == 1)      // iPad two-thirds Split View
        #expect(grid.columnCount(for: 735) == 1)
        #expect(grid.columnCount(for: 736) == 2)      // two 360 pt columns and a 16 pt gap
        #expect(grid.columnCount(for: 834) == 2)      // iPad Pro 11" portrait
        #expect(grid.columnCount(for: 868) == 2)      // iPhone Duo inner display, landscape
        #expect(grid.columnCount(for: 1194) == 3)     // iPad Pro 11" landscape
        #expect(grid.columnCount(for: 1366) == 3)     // iPad Pro 13" landscape
        #expect(grid.columnCount(for: nil) == 1)      // SwiftUI's unspecified probe
        #expect(grid.columnCount(for: .infinity) == 1)
    }

    // A short last row stretches its cards across the width instead of leaving cells empty
    @Test func shortLastRowStretchesAcrossTheWidth() async throws {
        let grid = FlowingCardGrid()
        #expect(grid.cellWidths(cardCount: 5, width: 868) == [[426, 426], [426, 426], [868]])        // Lifetime
        #expect(grid.cellWidths(cardCount: 6, width: 868) == [[426, 426], [426, 426], [426, 426]])   // This Year
        let landscape = grid.cellWidths(cardCount: 5, width: 1194)
        #expect(landscape.count == 2)
        #expect(landscape[0].count == 3)
        #expect(landscape[0].allSatisfy { abs($0 - 387.33) < 0.5 })
        #expect(landscape[1] == [589, 589])
        #expect(grid.cellWidths(cardCount: 2, width: 1194) == [[589, 589]])   // home not set: Elevation and Regions
        #expect(grid.cellWidths(cardCount: 3, width: 669) == [[669], [669], [669]])
        #expect(grid.cellWidths(cardCount: 0, width: 868).isEmpty)
        #expect(grid.cellWidths(cardCount: 2, width: nil) == [[360], [360]])
    }

    @Test func flowingGridRowsFillTheWidthExactly() async throws {
        let grid = FlowingCardGrid()
        for width: CGFloat in [393, 669, 736, 868, 1194, 1366] {
            for count in 1...7 {
                for row in grid.cellWidths(cardCount: count, width: width) {
                    let total = row.reduce(0, +) + CGFloat(row.count - 1) * grid.columnSpacing
                    #expect(abs(total - width) < 0.01, "\(count) cards at \(width)")
                }
            }
        }
    }
}
