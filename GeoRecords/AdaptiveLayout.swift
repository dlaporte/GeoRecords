//
//  AdaptiveLayout.swift
//  GeoRecords
//
//  Layout follows size classes, never the main screen (Apple's guidance for
//  iPad multitasking and iPhone Duo, whose inner display is regular/regular in
//  every pose and resizes the app live on fold), plus the window's width: the
//  Duo upright is regular at 669 pt, too narrow for a split view to tile. Both
//  values are computed from the view's own environment, so a sheet or a Split
//  View window gets its own answer and nothing is cached from a screen that may
//  be gone.
//

import SwiftUI

/// Whether a view has room for list-and-detail layouts
enum LayoutWidth: Equatable {
    case compact
    case regular

    /// Below this a regular-width window still gets the phone layouts: the Duo's
    /// inner display upright (669) and an iPad in two-thirds Split View (694) draw
    /// a split view's sidebar as a drawer over the detail instead of tiling, and
    /// the phone cards truncate inside it. The iPad mini (744) is the narrowest
    /// window known to tile.
    static let minimumRegularWidth: CGFloat = 720

    init(horizontal: UserInterfaceSizeClass?) {
        self.init(horizontal: horizontal, windowWidth: nil)
    }

    /// `windowWidth` nil means unmeasured (previews, a view outside the tab view):
    /// the size class alone decides
    init(horizontal: UserInterfaceSizeClass?, windowWidth: CGFloat?) {
        self.init(horizontal: horizontal, windowWidth: windowWidth, foldDivided: false)
    }

    /// `foldDivided`: the iPhone Duo held upright and partially folded, like a book.
    /// Its 669 pt display is too narrow to tile flat, but along the fold the system
    /// shows a split view as two even pages, so the list-and-detail layouts come back
    init(horizontal: UserInterfaceSizeClass?, windowWidth: CGFloat?, foldDivided: Bool) {
        let wideEnough = windowWidth.map { $0 >= Self.minimumRegularWidth } ?? true
        self = horizontal == .regular && (wideEnough || foldDivided) ? .regular : .compact
    }
}

extension EnvironmentValues {
    /// The scene window's width, measured by ContentView on the tab view; nil
    /// where nothing measured it
    @Entry var windowWidth: CGFloat? = nil

    /// The scene window's height, measured alongside the width
    @Entry var windowHeight: CGFloat? = nil

    /// Whether the window is currently divided by an active fold (the Duo's book
    /// pose); false on every other device and whenever the Duo is flat
    @Entry var foldDivided: Bool = false

    /// Whether the device has a hinge at all (the Duo), from the hinge API; false
    /// before iOS 27.1 and on every other device
    @Entry var deviceHasHinge: Bool = false

    /// Regular on iPad, iPhone Duo open in landscape and Max phones in landscape;
    /// compact elsewhere, including the Duo upright, one-third and two-thirds
    /// Split View and Slide Over. A sheet's own compact size class wins.
    var layoutWidth: LayoutWidth {
        LayoutWidth(horizontal: horizontalSizeClass, windowWidth: windowWidth)
    }

    /// `layoutWidth` plus the fold: the Records and Regions split views also tile in
    /// the Duo's book pose. Stats, History and Settings keep `layoutWidth`, spanning
    /// the crease as continuous content
    var splitLayoutWidth: LayoutWidth {
        LayoutWidth(horizontal: horizontalSizeClass, windowWidth: windowWidth, foldDivided: foldDivided)
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

/// Sidebar column widths for a NavigationSplitView. Only windows of at least
/// `LayoutWidth.minimumRegularWidth` show one, so 380 pt always leaves the detail
/// at least 340 pt (an iPad mini tiles with 364); narrower windows are compact.
struct SidebarWidth: Equatable {
    let minimum: CGFloat
    let ideal: CGFloat
    let maximum: CGFloat
}

extension View {
    /// Applies the widths unless the window is divided by a fold: in the Duo's book
    /// pose the system splits the columns evenly along the crease (334 pt pages), and
    /// a 340 pt minimum would fight it
    @ViewBuilder
    func navigationSplitViewColumnWidth(_ width: SidebarWidth, unlessFoldDivided foldDivided: Bool = false) -> some View {
        if foldDivided {
            self
        } else {
            navigationSplitViewColumnWidth(min: width.minimum, ideal: width.ideal, max: width.maximum)
        }
    }
}

/// How a split view's detail column lays out the record below its heading and map
enum DetailColumnStyle: Equatable {
    /// The photo beside the detail cards (iPads in landscape)
    case wide
    /// The photo above the detail cards (iPad portrait, the Duo in landscape, a
    /// book-pose page)
    case stacked

    /// Two columns of a 4:3 photo and readable rows need about this much
    static let minimumWideWidth: CGFloat = 720
    /// A panel shorter than this cannot show a photo and a row
    static let minimumPanelHeight: CGFloat = 300

    static func style(forColumnWidth width: CGFloat) -> DetailColumnStyle {
        width >= minimumWideWidth ? .wide : .stacked
    }

    /// The panel's share of the height under the heading: 40% when the photo sits
    /// beside the rows, 60% when it sits above them, never under 300 pt; the map
    /// gets what remains. A measured content height shorter than that share takes
    /// only what it needs (a region without a photo: two cards), the map the rest
    static func panelHeight(forColumnHeight height: CGFloat, style: DetailColumnStyle, contentHeight: CGFloat? = nil) -> CGFloat {
        let share: CGFloat = style == .wide ? 0.4 : 0.6
        let cap = min(max(height * share, minimumPanelHeight), height)
        guard let contentHeight, contentHeight > 0 else { return cap }
        return min(contentHeight, cap)
    }
}

/// Capsule pills wrapping onto as many rows as they need, left-aligned (the
/// History filter panel's type and source choices)
struct PillFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.indices.append(index)
            row.width = row.indices.count == 1 ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Where a split view's detail column keeps share and delete: trailing, as a
/// navigation bar normally does, except on the Duo in landscape, where the window
/// has no top tab bar and its trailing edge sits against the display's clock and
/// tab rail. Only a hinged device under 720 pt tall is that window; the book pose
/// (951 tall) and every iPad stay trailing
enum DetailActionsPlacement {
    static func leading(hasHinge: Bool, windowHeight: CGFloat?) -> Bool {
        guard hasHinge, let windowHeight else { return false }
        return windowHeight < LayoutWidth.minimumRegularWidth
    }
}

/// A place name that would wrap breaks after its first comma instead:
/// "Shinjuku, Tokyo, Japan" becomes "Shinjuku," over "Tokyo, Japan"
enum PlaceName {
    static func lines(_ name: String) -> (first: String, rest: String)? {
        guard let comma = name.firstIndex(of: ",") else { return nil }
        let rest = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (String(name[...comma]), rest)
    }
}

/// The navigation stack of a tab with a single column (Stats, Settings). Under the
/// regular-width top tab bar, iPadOS places a plain NavigationStack's large title
/// 14 pt lower than a NavigationSplitView column's, so these tabs looked sunk beside
/// Records, Regions and History; hosting the stack as a split view's only column
/// lines the titles up. On compact width a split view would collapse to its empty
/// sidebar, so iPhones and the folded Duo keep the plain stack. Presentations
/// (sheets, alerts) belong outside this view: its branch changes on fold.
struct SingleColumnTab<Content: View>: View {
    @Environment(\.layoutWidth) private var layoutWidth
    @ViewBuilder let content: Content

    var body: some View {
        if layoutWidth == .regular {
            NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
                EmptyView()
                    .toolbar(removing: .sidebarToggle)  // the only placement that removes it
            } detail: {
                NavigationStack { content }
                    .background(SidebarSwipeDisabler())
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack { content }
        }
    }
}

/// Turns off the split view's leading-edge swipe, which slides the empty sidebar in
/// over the column even with the visibility bound to a constant (a zero-width sidebar
/// doesn't stop it either); SwiftUI has no switch for it, UIKit does
private struct SidebarSwipeDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ uiView: Finder, context: Context) {}

    final class Finder: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            disableSwipe()
            DispatchQueue.main.async { [weak self] in self?.disableSwipe() }  // the split view may attach later
        }

        private func disableSwipe() {
            var responder: UIResponder? = self
            while let current = responder {
                if let split = current as? UISplitViewController {
                    split.presentsWithGesture = false
                    return
                }
                responder = current.next
            }
        }
    }
}

// MARK: - Map card

extension View {
    /// A tab screen's map strip as a rounded card inside the content margins, flush
    /// with the picker above and the cards below (and clear of the Duo's tab rail,
    /// which the safe area already excludes)
    func mapCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal)
    }
}

// MARK: - Minimal back button

/// Pages pushed from this view show the back button as a chevron alone, which
/// frees the title room on the folded Duo. SwiftUI has no modifier for it; UIKit's
/// `backButtonDisplayMode` on the root's navigation item is what the pushed page reads
struct MinimalBackButton: UIViewRepresentable {
    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ uiView: Finder, context: Context) {}

    final class Finder: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            minimize()
            DispatchQueue.main.async { [weak self] in self?.minimize() }
        }

        private func minimize() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, controller.navigationController != nil {
                    controller.navigationItem.backButtonDisplayMode = .minimal
                    return
                }
                responder = current.next
            }
        }
    }
}

extension View {
    /// Pages pushed from here get a chevron-only back button
    func minimalBackButton() -> some View {
        background(MinimalBackButton())
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
    @Environment(\.layoutWidth) private var layoutWidth

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GEORECORDS_SHOW_SIZE_CLASS"] == "1"
    }

    var body: some View {
        GeometryReader { geometry in
            Text("h:\(name(horizontal)) v:\(name(vertical)) \(Int(geometry.size.width))×\(Int(geometry.size.height)) layout:\(layoutWidth == .regular ? "R" : "C")")
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
