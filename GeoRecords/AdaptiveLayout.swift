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

/// Stats cards stack on iPhone and tile on wider screens
enum StatsGrid {
    static func columns(for width: LayoutWidth) -> [GridItem] {
        switch width {
        case .compact: return [GridItem(.flexible())]
        case .regular: return [GridItem(.adaptive(minimum: 360), spacing: 16)]
        }
    }
}

/// Sidebar column widths for a NavigationSplitView. Under 720 pt (iPhone Duo inner
/// display 669, iPad two-thirds Split View 694) a 380 pt sidebar leaves too little
/// for the detail and iOS overlays the sidebar instead of tiling; 300 pt leaves at
/// least 369 pt, which is known to tile (an iPad mini tiles with 364).
struct SidebarWidth: Equatable {
    let minimum: CGFloat
    let ideal: CGFloat
    let maximum: CGFloat

    static let narrowWindow: CGFloat = 720
    static let narrow = SidebarWidth(minimum: 280, ideal: 300, maximum: 320)

    static func forWindow(width: CGFloat, roomy: SidebarWidth) -> SidebarWidth {
        width < narrowWindow ? narrow : roomy
    }
}

extension View {
    func navigationSplitViewColumnWidth(_ width: SidebarWidth) -> some View {
        navigationSplitViewColumnWidth(min: width.minimum, ideal: width.ideal, max: width.maximum)
    }
}

// MARK: - Readable width

private struct ReadableWidth: ViewModifier {
    @Environment(\.layoutWidth) private var layoutWidth

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: layoutWidth == .regular ? 720 : .infinity)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Caps text-heavy content (forms, lists of settings) at 720 pt and centers it
    /// in regular width, the standard iPad treatment; a no-op in compact width
    func readableWidth() -> some View {
        modifier(ReadableWidth())
    }
}

// MARK: - Size-class badge (debug tours only)

#if DEBUG
/// Shows the size classes and window size in a corner when the app is launched
/// with GEORECORDS_SHOW_SIZE_CLASS=1 (the screenshot tour sets it), so a capture
/// documents the layout environment it was taken in
struct SizeClassBadge: View {
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GEORECORDS_SHOW_SIZE_CLASS"] == "1"
    }

    var body: some View {
        GeometryReader { geometry in
            Text("h:\(name(horizontal)) v:\(name(vertical)) \(Int(geometry.size.width))×\(Int(geometry.size.height))")
                .font(.caption2.monospaced())
                .padding(4)
                .background(Color.yellow.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
        }
    }

    private func name(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: return "C"
        case .regular: return "R"
        default: return "?"
        }
    }
}
#endif
