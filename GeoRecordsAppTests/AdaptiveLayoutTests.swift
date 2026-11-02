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
}
