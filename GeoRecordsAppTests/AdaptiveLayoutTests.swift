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

    // A 380 pt sidebar on the Duo's 669 pt inner display leaves 289 pt for the detail
    // and iOS overlays the sidebar instead of tiling; the iPad mini (744) tiles with 364
    @Test func sidebarNarrowsBelow720Points() async throws {
        let roomy = SidebarWidth(minimum: 340, ideal: 380, maximum: 440)
        #expect(SidebarWidth.forWindow(width: 834, roomy: roomy) == roomy)   // iPad Pro 11" portrait
        #expect(SidebarWidth.forWindow(width: 744, roomy: roomy) == roomy)   // iPad mini portrait
        #expect(SidebarWidth.forWindow(width: 720, roomy: roomy) == roomy)
        #expect(SidebarWidth.forWindow(width: 719, roomy: roomy) == .narrow)
        #expect(SidebarWidth.forWindow(width: 694, roomy: roomy) == .narrow) // iPad two-thirds Split View
        #expect(SidebarWidth.forWindow(width: 669, roomy: roomy) == .narrow) // iPhone Duo inner display
        #expect(SidebarWidth.narrow == SidebarWidth(minimum: 280, ideal: 300, maximum: 320))
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
