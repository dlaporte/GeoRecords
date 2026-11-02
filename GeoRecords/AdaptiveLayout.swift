//
//  AdaptiveLayout.swift
//  GeoRecords
//
//  Layout follows size classes, never the main screen (Apple's guidance for
//  iPad multitasking and iPhone Duo, whose inner display is regular/regular in
//  every pose and resizes the app live on fold). Both values are computed from
//  the view's own environment, so a sheet or a Split View window gets its own
//  answer and nothing is cached from a screen that may be gone.
//

import SwiftUI

/// Whether a view has room for list-and-detail layouts
enum LayoutWidth: Equatable {
    case compact
    case regular

    init(horizontal: UserInterfaceSizeClass?) {
        self = horizontal == .regular ? .regular : .compact
    }
}

extension EnvironmentValues {
    /// Regular on iPad, iPhone Duo open and Max phones in landscape; compact
    /// elsewhere, including one-third Split View and Slide Over
    var layoutWidth: LayoutWidth {
        LayoutWidth(horizontal: horizontalSizeClass)
    }

    /// Card metrics for this view's height class
    var cardSizing: CardSizing {
        CardSizing(vertical: verticalSizeClass)
    }
}
