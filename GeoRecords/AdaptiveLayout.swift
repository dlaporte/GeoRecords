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

/// Rows of equal-width columns, as many as fit at the minimum width, for the Stats
/// cards where they tile; a short last row stretches its cards across the full width
/// so no cell is left empty. (One grid per section left every odd card alone on the
/// left: the staircase the iPhone Duo inner display and iPad portrait showed.)
struct FlowingCardGrid: Layout {
    var minimumColumnWidth: CGFloat = 360
    /// Cards add their own 16 pt side padding, so 48 pt shows between columns
    var columnSpacing: CGFloat = 16
    var rowSpacing: CGFloat = 16

    /// Columns that fit: 1 under 736 pt (iPhones, the Duo inner display upright, iPad
    /// two-thirds Split View), 2 at the Duo's 868 pt landscape window and iPad portrait,
    /// 3 on an iPad in landscape. SwiftUI also probes with nil and infinite widths: 1.
    func columnCount(for width: CGFloat?) -> Int {
        guard let width, width.isFinite else { return 1 }
        return max(1, Int(((width + columnSpacing) / (minimumColumnWidth + columnSpacing)).rounded(.down)))
    }

    /// Cell widths per row: full rows of `columnCount` cells, then a last row whose
    /// cards share the width equally
    func cellWidths(cardCount: Int, width: CGFloat?) -> [[CGFloat]] {
        guard cardCount > 0 else { return [] }
        let usable = usableWidth(width)
        let columns = columnCount(for: width)
        return stride(from: 0, to: cardCount, by: columns).map { start in
            let cells = min(columns, cardCount - start)
            let cell = (usable - CGFloat(cells - 1) * columnSpacing) / CGFloat(cells)
            return Array(repeating: cell, count: cells)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * rowSpacing
        return CGSize(width: usableWidth(proposal.width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.cards {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: row.cellWidth, height: nil))
                x += row.cellWidth + columnSpacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        let cards: Range<Int>
        let cellWidth: CGFloat
        /// The tallest card at the cell width; cards keep their natural height, top-aligned
        let height: CGFloat
    }

    /// The same rows for measuring and placing, so the two can't disagree
    private func rows(width: CGFloat?, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var start = 0
        for widths in cellWidths(cardCount: subviews.count, width: width) {
            let cards = start..<(start + widths.count)
            let cellWidth = widths[0]
            let height = cards.map { subviews[$0].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
            rows.append(Row(cards: cards, cellWidth: cellWidth, height: height))
            start = cards.upperBound
        }
        return rows
    }

    private func usableWidth(_ width: CGFloat?) -> CGFloat {
        guard let width, width.isFinite else { return minimumColumnWidth }
        return width
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
