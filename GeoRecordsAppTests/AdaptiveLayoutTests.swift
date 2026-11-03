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
}
