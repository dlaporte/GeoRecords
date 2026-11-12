import SwiftUI
import MapKit
import WidgetKit

// MARK: - Maps Tab View

/// Container view for the Maps tab with segmented picker for States/Countries/Continents
struct MapsTabView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared
    @EnvironmentObject private var deepLinkManager: DeepLinkManager
    @Environment(RegionsTabState.self) private var state

    enum MapType: String, CaseIterable {
        case states = "States"
        case countries = "Countries"
        case continents = "Continents"
    }

    @Environment(\.layoutWidth) private var layoutWidth

    var body: some View {
        Group {
            if layoutWidth == .regular {
                // Each section builds a split view: picker and banner go in its sidebar
                switch state.mapType {
                case .states:
                    StatesMapView(sidebarHeader: AnyView(sectionHeader))
                case .countries:
                    CountriesMapView(sidebarHeader: AnyView(sectionHeader))
                case .continents:
                    ContinentsMapView(sidebarHeader: AnyView(sectionHeader))
                }
            } else {
                NavigationStack {
                    VStack(spacing: 0) {
                        sectionHeader

                        // Map content
                        switch state.mapType {
                        case .states:
                            StatesMapView()
                        case .countries:
                            CountriesMapView()
                        case .continents:
                            ContinentsMapView()
                        }
                    }
                    .navigationTitle("Regions")
                }
            }
        }
        .onAppear {
            handleDeepLink()
        }
        .onChange(of: deepLinkManager.navigateToRegions) { _, _ in
            handleDeepLink()
        }
    }

    /// Segmented picker plus the catch-up confirmation banner when there is one
    private var sectionHeader: some View {
        @Bindable var state = state
        return VStack(spacing: 0) {
            StyledSegmentedPicker(
                selection: $state.mapType,
                options: MapType.allCases,
                label: { $0.rawValue }
            )
            .padding()

            // Regions found by the automatic photo catch-up, awaiting confirmation
            if !regionManager.pendingRegions.isEmpty {
                PendingRegionsBanner(regionManager: regionManager)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }

    private func handleDeepLink() {
        guard let section = deepLinkManager.navigateToRegions else { return }
        state.apply(section: section)
        deepLinkManager.navigateToRegions = nil
    }
}

// MARK: - Pending Regions Banner

/// Compact confirmation list for regions discovered by the automatic photo catch-up.
/// Confirming records the visit through the normal path; dismissing forgets it.
private struct PendingRegionsBanner: View {
    @ObservedObject var regionManager: RegionTrackingManager
    @State private var confirmCount = 0  // haptic trigger

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("New places found in your photos", systemImage: "sparkles")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(regionManager.pendingRegions) { pending in
                HStack(spacing: 8) {
                    if let flag = FormatUtils.flagEmoji(for: pending.code, recordType: pending.regionType == RegionType.state.rawValue ? RecordType.state.rawValue : RecordType.country.rawValue) {
                        Text(flag)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pending.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(pending.date, style: .date)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        confirmCount += 1
                        withAnimation {
                            regionManager.confirmPendingRegion(code: pending.code)
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Confirm \(pending.name)")
                    Button {
                        withAnimation {
                            regionManager.dismissPendingRegion(code: pending.code)
                        }
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .sensoryFeedback(.success, trigger: confirmCount)
    }
}

// MARK: - Visited Region Card Component

struct VisitedRegionCard: View {
    let detail: RecordDetail
    @EnvironmentObject var settings: SettingsManager
    @ObservedObject private var regionManager = RegionTrackingManager.shared

    @Environment(\.cardSizing) private var sizing

    private var firstVisitedText: String {
        "First visited \(detail.timestamp.formatted(.dateTime.month(.abbreviated).year()))"
    }

    private var visitsText: String? {
        guard let code = detail.regionCode, let type = RecordType.from(string: detail.recordType) else { return nil }
        let summary = regionManager.visitSummary(code: code, type: type)
        return VisitLog.text(count: summary.count, last: summary.last)
    }

    /// Distance from home to where the region was first entered
    private var fromHomeText: String? {
        FormatUtils.formatDistanceFromHome(from: detail.coordinate, to: settings.homeCoordinate, unitSystem: settings.unitSystem)
            .map { "\($0) from home" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sizing.cardSpacing) {
            // The region itself heads the card; the segmented control names its kind
            HStack(spacing: sizing.isCompact ? 8 : 12) {
                Image(systemName: FormatUtils.iconForRecordType(detail.recordType))
                    .font(sizing.isCompact ? .title3 : .title)
                    .foregroundColor(FormatUtils.colorForRecordType(detail.recordType))
                    .frame(width: sizing.iconSize, height: sizing.iconSize)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let flag = FormatUtils.flagEmoji(for: detail.regionCode, recordType: detail.recordType) {
                            Text(flag)
                                .font(sizing.isCompact ? .body : .title3)
                        }
                        Text(detail.locationName ?? "Unknown")
                            .font(sizing.isCompact ? .caption : .headline)
                            .fontWeight(.semibold)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    Text(firstVisitedText)
                        .font(sizing.isCompact ? .caption2 : .caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if !sizing.isCompact {
                Divider()
            }

            // Main content with photo on the right
            HStack(alignment: .top, spacing: sizing.isCompact ? 8 : 16) {
                VStack(alignment: .leading, spacing: sizing.contentSpacing) {
                    // Repeat visits ("3 visits · last Aug 2026")
                    if let visitsText {
                        VStack(alignment: .leading, spacing: 2) {
                            if !sizing.isCompact {
                                Text("Visits")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(visitsText)
                                .font(sizing.isCompact ? .caption2 : .subheadline)
                        }
                    }

                    if !sizing.isCompact, let fromHomeText {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("From Home")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(fromHomeText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Right side - photo thumbnail
                if detail.photoAssetIdentifier != nil || detail.photoData != nil {
                    RecordPhotoThumbnail(
                        recordId: detail.id,
                        photoAssetIdentifier: detail.photoAssetIdentifier,
                        photoCloudIdentifier: detail.photoCloudIdentifier,
                        photoData: detail.photoData,
                        timestamp: detail.timestamp,
                        coordinate: detail.coordinate,
                        sizing: sizing
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(sizing.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: sizing.isCompact ? 16 : 20)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal, sizing.horizontalPadding)
    }

}

// MARK: - Shared Region Cards + Map Layout

/// Shared layout for the three region tabs (states/countries/continents):
/// a map with a stats-header overlay and widget button, above swipeable region cards.
/// The tab-specific pieces (map view, region math, sheet, empty state) come in as
/// closures; everything else previously existed as three ~105-line verbatim copies.
private struct RegionCardsMapView<MapV: View, SheetV: View, EmptyV: View>: View {
    /// Segment picker and pending banner, shown at the top of the sidebar in regular width
    var sidebarHeader: AnyView = AnyView(EmptyView())
    let regions: [RecordDetail]
    let statsIcon: String
    let statsIconColor: Color
    let statsText: String
    let widgetButtonHighlighted: Bool
    /// The kind of this tab's regions, for the distance in the unvisited-tap callout
    let notYetKind: NotYetKind
    /// Camera when no card is selected
    let defaultCamera: MKCoordinateRegion
    /// Maps a tapped map coordinate to the index of the matching card (nil = no card)
    let cardIndex: (CLLocationCoordinate2D) -> Int?
    /// Maps a tapped coordinate to an unvisited region of this tab's kind (nil = none)
    let unvisitedRegion: (CLLocationCoordinate2D) -> NotYetRegion?
    /// Builds the map: the current card and the tap handler
    @ViewBuilder let mapView: (RecordDetail?, _ onTap: @escaping (CLLocationCoordinate2D) -> Void) -> MapV
    @ViewBuilder let widgetSheet: () -> SheetV
    @ViewBuilder let emptyState: () -> EmptyV

    @EnvironmentObject private var settings: SettingsManager
    @Environment(RegionsTabState.self) private var state
    @Environment(\.splitLayoutWidth) private var layoutWidth
    @Environment(\.foldDivided) private var foldDivided
    @Environment(\.cardSizing) private var sizing
    @State private var currentCardIndex = 0
    @State private var selectedDetail: RecordDetail?
    @State private var navigateToDetail = false
    @State private var showWidgetViewSetter = false
    @State private var callout: UnvisitedCallout?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Current region to display on map
    private var currentRegion: RecordDetail? {
        focusedRegion
    }

    // Tapping a visited region on the map swipes the card carousel to it; tapping
    // an unvisited one shows a callout instead
    private func selectCard(at coordinate: CLLocationCoordinate2D) {
        if let index = cardIndex(coordinate) {
            callout = nil
            withAnimation(.easeInOut(duration: 0.2)) {
                currentCardIndex = index
            }
            return
        }
        if let region = unvisitedRegion(coordinate) {
            showCallout(for: region)
        } else {
            callout = nil
        }
    }

    /// The callout for an unvisited region; its nearest-border distance from home is
    /// computed for that one region off the main actor and lands a moment later
    private func showCallout(for region: NotYetRegion) {
        withAnimation(.easeInOut(duration: 0.2)) {
            callout = UnvisitedCallout(name: region.name, code: region.code, distanceText: nil)
        }
        guard let home = settings.homeCoordinate else { return }
        let kind = notYetKind
        let unitSystem = settings.unitSystem
        Task {
            let meters = await Task.detached(priority: .utility) {
                RegionDistance.nearestMeters(from: home, polygons: kind.polygons(for: region.code))
            }.value
            guard let meters, callout?.code == region.code else { return }
            callout = UnvisitedCallout(name: region.name, code: region.code,
                                       distanceText: RegionDistance.approximateText(meters: meters, unitSystem: unitSystem))
        }
    }

    var body: some View {
        Group {
            if layoutWidth == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .sheet(isPresented: $showWidgetViewSetter) {
            widgetSheet()
        }
        .onChange(of: currentCardIndex) { _, newIndex in
            // The carousel index and the hoisted selection stay in step, so a fold or
            // a Split View resize that swaps layouts lands on the same region
            if let code = regions[safe: newIndex]?.regionCode, state.selectedRegionCode != code {
                state.selectedRegionCode = code
            }
        }
        .onAppear {
            if let code = state.selectedRegionCode,
               let index = regions.firstIndex(where: { $0.regionCode == code }),
               index != currentCardIndex {
                currentCardIndex = index
            }
        }
    }

    // MARK: - Layouts

    /// iPhone: the map with the stats header overlaid, above swipeable cards; beside
    /// them in compact height (a phone in landscape), where stacking left no map
    private var compactLayout: some View {
        let stack = sizing.isCompact ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return stack {
            ZStack(alignment: .top) {
                mapPane
                statsHeader
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemBackground).opacity(0.9))
                    .cornerRadius(8)
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
            }
            .mapCard()
            .padding(.top, 12)
            .minimalBackButton()

            // The region cards, or the visited list when Settings says List
            if regions.isEmpty {
                Spacer()
                emptyState()
                Spacer()
            } else if settings.listLayout == .list {
                VisitedList(regions: regions, selectedID: focusedRegion?.id) { index in
                    selectRegion(at: index, open: true)
                }
                .frame(width: sizing.isCompact ? 360 : nil)
                .frame(height: sizing.isCompact ? nil : cardTabViewHeight)
                .padding(.vertical, 10)
            } else {
                TabView(selection: $currentCardIndex) {
                    ForEach(Array(regions.enumerated()), id: \.element.id) { index, detail in
                        VisitedRegionCard(detail: detail)
                            .tag(index)
                            .onTapGesture {
                                selectedDetail = detail
                                navigateToDetail = true
                            }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .contentMargins(0, for: .scrollContent)
                .frame(width: sizing.isCompact ? 360 : nil)
                .frame(maxWidth: .infinity)
                .frame(height: sizing.isCompact ? nil : cardTabViewHeight)
                .padding(.vertical, 12)
            }
        }
        .navigationDestination(isPresented: $navigateToDetail) {
            if let detail = selectedDetail {
                RecordDetailView(record: detail)
            }
        }
    }

    /// A row of the Visited list: the carousel and the map follow it; a phone also
    /// opens the region, as tapping its card does
    private func selectRegion(at index: Int, open: Bool) {
        callout = nil
        currentCardIndex = index
        if open, let detail = regions[safe: index] {
            selectedDetail = detail
            navigateToDetail = true
        }
    }

    /// iPad, iPhone Duo open, Max phones in landscape: the segment picker, stats
    /// header and region cards as a selectable sidebar; the map fills the detail
    /// column with the selected region's detail in a collapsible panel beneath it
    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                sidebarHeader
                statsHeader
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                if regions.isEmpty {
                    Spacer()
                    emptyState()
                    Spacer()
                } else if settings.listLayout == .list {
                    VisitedList(regions: regions, selectedID: focusedRegion?.id) { index in
                        selectRegion(at: index, open: false)
                    }
                } else {
                    regionList
                }
            }
            .navigationTitle("Regions")
            .navigationSplitViewColumnWidth(SidebarWidth(minimum: 340, ideal: 380, maximum: 440), unlessFoldDivided: foldDivided)
        } detail: {
            if let region = focusedRegion {
                RecordDetailView(record: region, style: .column, map: AnyView(mapPane))
                    .id(region.id)
            } else {
                mapPane
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Map showing the current region, with the unvisited-tap callout overlaid at the bottom
    private var mapPane: some View {
        mapView(currentRegion, selectCard)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if let callout {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle")
                            .foregroundColor(.secondary)
                        Text(callout.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("· not yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let distanceText = callout.distanceText {
                            Text("· \(distanceText)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemBackground).opacity(0.9))
                    .cornerRadius(8)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .task(id: callout) {
                        try? await Task.sleep(for: .seconds(4))
                        if !Task.isCancelled {
                            withAnimation { self.callout = nil }
                        }
                    }
                }
            }
    }

    /// "14 of 50 states visited" and the widget button
    private var statsHeader: some View {
        HStack {
            Image(systemName: statsIcon)
                .foregroundColor(statsIconColor)
            Text(statsText)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                showWidgetViewSetter = true
            } label: {
                Image(systemName: widgetButtonHighlighted ? "widget.small.badge.plus" : "widget.small")
                    .font(.system(size: 16))
                    .foregroundColor(.blue)
            }
            .hoverEffect(.highlight)
            .accessibilityLabel("Widget map view")
        }
    }

    /// The region cards as a scrolling stack (regular width); tapping one frames the
    /// map. Not a List: list selection repaints the selected card's text white and
    /// adds its own focus rectangle, so the ring below marks the selection
    private var regionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(regions.enumerated()), id: \.element.id) { index, detail in
                        Button {
                            callout = nil
                            currentCardIndex = index
                        } label: {
                            VisitedRegionCard(detail: detail)
                                .overlay {
                                    if focusedRegion?.id == detail.id {
                                        RoundedRectangle(cornerRadius: sizing.isCompact ? 16 : 20)
                                            .strokeBorder(Color.accentColor, lineWidth: 3)
                                            .padding(.horizontal, sizing.horizontalPadding)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                        .accessibilityAddTraits(focusedRegion?.id == detail.id ? .isSelected : [])
                        .id(detail.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: currentCardIndex) { _, index in
                if let id = regions[safe: index]?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// The region the map frames and the detail panel shows: the hoisted selection
    /// when it is in this list, else the carousel's card, else the first region
    private var focusedRegion: RecordDetail? {
        if let code = state.selectedRegionCode, let region = regions.first(where: { $0.regionCode == code }) {
            return region
        }
        return regions[safe: currentCardIndex] ?? regions.first
    }
}

// MARK: - Visited List

/// The visited regions as a dense list, in the cards' order: a row selects the
/// region (and opens it on a phone)
private struct VisitedList: View {
    let regions: [RecordDetail]
    let selectedID: UUID?
    let onSelect: (Int) -> Void
    @ObservedObject private var regionManager = RegionTrackingManager.shared

    private func visitsText(_ detail: RecordDetail) -> String? {
        guard let code = detail.regionCode, let type = RecordType.from(string: detail.recordType) else { return nil }
        let summary = regionManager.visitSummary(code: code, type: type)
        return VisitLog.text(count: summary.count, last: summary.last)
    }

    var body: some View {
        if regions.isEmpty {
            ContentUnavailableView("No regions yet", systemImage: "map",
                                   description: Text("Visited regions appear here."))
        } else {
            List(Array(regions.enumerated()), id: \.element.id) { index, detail in
                Button {
                    onSelect(index)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: FormatUtils.iconForRecordType(detail.recordType))
                            .foregroundColor(FormatUtils.colorForRecordType(detail.recordType))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if let flag = FormatUtils.flagEmoji(for: detail.regionCode, recordType: detail.recordType) {
                                    Text(flag)
                                }
                                Text(detail.locationName ?? "Unknown")
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            }
                            Text("First visited \(detail.timestamp.formatted(.dateTime.month(.abbreviated).year()))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let visits = visitsText(detail) {
                            Text(visits)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(selectedID == detail.id ? Color.accentColor.opacity(0.12) : Color.clear)
                .accessibilityAddTraits(selectedID == detail.id ? .isSelected : [])
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - States Map View

/// Shows visited US states as cards
struct StatesMapView: View {
    var sidebarHeader: AnyView = AnyView(EmptyView())
    @StateObject private var regionManager = RegionTrackingManager.shared

    // Sorted states alphabetically by name
    private var sortedStates: [RecordDetail] {
        regionManager.visitedStates.sorted { ($0.locationName ?? "") < ($1.locationName ?? "") }
    }

    // Map region for a card (center and span; cached per region code)
    private func mapRegion(for region: RecordDetail?) -> (center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        let defaultRegion = MKCoordinateRegion(center: defaultUSMapCenter, span: defaultUSStateSpan)

        guard let region = region, let code = region.regionCode else {
            return (defaultRegion.center, defaultRegion.span)
        }

        let calculatedRegion = RegionOverlayCache.shared.cameraRegion(for: code, defaultRegion: defaultRegion)
        return (calculatedRegion.center, calculatedRegion.span)
    }

    var body: some View {
        let visitedCodes = Set(sortedStates.compactMap { $0.regionCode.map { normalizeRegionCode($0, isState: true) } })
        RegionCardsMapView(
            sidebarHeader: sidebarHeader,
            regions: sortedStates,
            statsIcon: "flag.fill",
            statsIconColor: .orange,
            statsText: "\(regionManager.stateCount) of 50 states visited",
            widgetButtonHighlighted: SettingsManager.shared.widgetMapStatesRegion != nil,
            notYetKind: .state,
            defaultCamera: MKCoordinateRegion(center: defaultUSMapCenter, span: defaultUSStateSpan),
            cardIndex: { coordinate in
                guard let info = RegionLookupService.shared.region(for: coordinate),
                      info.type == .state else { return nil }
                return sortedStates.firstIndex { $0.regionCode == info.code }
            },
            unvisitedRegion: { coordinate in
                guard let info = RegionLookupService.shared.region(for: coordinate),
                      info.type == .state else { return nil }
                let code = normalizeRegionCode(info.code, isState: true)
                return visitedCodes.contains(code) ? nil : NotYetRegion(code: code, name: info.name)
            },
            mapView: { current, onTap in
                let region = mapRegion(for: current)
                RegionMapView(
                    regionType: .state,
                    visitedRegions: sortedStates,
                    currentRegion: current,
                    centerCoordinate: region.center,
                    span: region.span,
                    onTap: onTap
                )
            },
            widgetSheet: {
                WidgetViewSetterSheet(mapType: "states", visitedRegions: sortedStates)
            },
            emptyState: {
                EmptyRegionStateView(regionType: .state)
            }
        )
    }
}

// MARK: - Countries Map View

/// Shows visited countries as cards
struct CountriesMapView: View {
    var sidebarHeader: AnyView = AnyView(EmptyView())
    @StateObject private var regionManager = RegionTrackingManager.shared

    // Sorted countries alphabetically by name
    private var sortedCountries: [RecordDetail] {
        regionManager.visitedCountries.sorted { ($0.locationName ?? "") < ($1.locationName ?? "") }
    }

    // Map region for a card (center and span; cached per region code)
    private func mapRegion(for region: RecordDetail?) -> (center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        let defaultRegion = MKCoordinateRegion(center: defaultWorldMapCenter, span: defaultCountrySpan)

        guard let region = region, let code = region.regionCode else {
            return (defaultRegion.center, defaultRegion.span)
        }

        let calculatedRegion = RegionOverlayCache.shared.cameraRegion(for: code, defaultRegion: defaultRegion)
        return (calculatedRegion.center, calculatedRegion.span)
    }

    var body: some View {
        let visitedCodes = Set(sortedCountries.compactMap(\.regionCode))
        RegionCardsMapView(
            sidebarHeader: sidebarHeader,
            regions: sortedCountries,
            statsIcon: "globe.americas.fill",
            statsIconColor: .blue,
            statsText: "\(regionManager.countryCount) of 195 countries visited",
            widgetButtonHighlighted: SettingsManager.shared.widgetMapCountriesRegion != nil,
            notYetKind: .country,
            defaultCamera: MKCoordinateRegion(center: defaultWorldMapCenter, span: defaultCountrySpan),
            cardIndex: { coordinate in
                guard let info = RegionLookupService.shared.region(for: coordinate) else { return nil }
                // A tap on a US state should select the United States card
                let countryCode = info.type == .state ? "US" : info.code
                return sortedCountries.firstIndex { $0.regionCode == countryCode }
            },
            unvisitedRegion: { coordinate in
                guard let info = RegionLookupService.shared.region(for: coordinate) else { return nil }
                let code = info.type == .state ? "US" : info.code
                let name = info.type == .state ? "United States" : info.name
                return visitedCodes.contains(code) ? nil : NotYetRegion(code: code, name: name)
            },
            mapView: { current, onTap in
                let region = mapRegion(for: current)
                RegionMapView(
                    regionType: .country,
                    visitedRegions: sortedCountries,
                    currentRegion: current,
                    centerCoordinate: region.center,
                    span: region.span,
                    onTap: onTap
                )
            },
            widgetSheet: {
                WidgetViewSetterSheet(mapType: "countries", visitedRegions: sortedCountries)
            },
            emptyState: {
                EmptyRegionStateView(regionType: .country)
            }
        )
    }
}

// MARK: - Continents Map View

/// Shows visited continents as cards
struct ContinentsMapView: View {
    var sidebarHeader: AnyView = AnyView(EmptyView())
    @StateObject private var regionManager = RegionTrackingManager.shared

    // Sorted continents alphabetically by name
    private var sortedContinents: [RecordDetail] {
        regionManager.visitedContinents.sorted { ($0.locationName ?? "") < ($1.locationName ?? "") }
    }

    private var visitedContinentsSet: Set<Continent> {
        Set(sortedContinents.compactMap { Continent(rawValue: $0.locationName ?? "") })
    }

    // Map region for a card (center and span based on continent bounds; cached per continent)
    private func mapRegion(for region: RecordDetail?) -> (center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        let defaultRegion = MKCoordinateRegion(center: defaultWorldMapCenter, span: defaultContinentSpan)

        guard let region = region,
              let continent = Continent(rawValue: region.locationName ?? "") else {
            return (defaultRegion.center, defaultRegion.span)
        }

        let calculatedRegion = RegionOverlayCache.shared.cameraRegion(for: continent, defaultRegion: defaultRegion)
        return (calculatedRegion.center, calculatedRegion.span)
    }

    var body: some View {
        let visitedCodes = Set(visitedContinentsSet.map(\.rawValue))
        RegionCardsMapView(
            sidebarHeader: sidebarHeader,
            regions: sortedContinents,
            statsIcon: "globe",
            statsIconColor: .purple,
            statsText: "\(regionManager.continentCount) of 7 continents visited",
            widgetButtonHighlighted: SettingsManager.shared.widgetMapContinentsRegion != nil,
            notYetKind: .continent,
            defaultCamera: MKCoordinateRegion(center: defaultWorldMapCenter, span: defaultContinentSpan),
            cardIndex: { coordinate in
                guard let continent = RegionLookupService.shared.region(for: coordinate)?.continent else { return nil }
                return sortedContinents.firstIndex { Continent(rawValue: $0.locationName ?? "") == continent }
            },
            unvisitedRegion: { coordinate in
                guard let continent = RegionLookupService.shared.region(for: coordinate)?.continent,
                      !visitedContinentsSet.contains(continent) else { return nil }
                return NotYetRegion(code: continent.rawValue, name: continent.rawValue)
            },
            mapView: { current, onTap in
                let region = mapRegion(for: current)
                ContinentMapView(
                    visitedContinents: visitedContinentsSet,
                    currentContinent: current.flatMap { Continent(rawValue: $0.locationName ?? "") },
                    centerCoordinate: region.center,
                    span: region.span,
                    onTap: onTap
                )
            },
            widgetSheet: {
                WidgetViewSetterSheet(mapType: "continents", visitedRegions: sortedContinents, visitedContinents: visitedContinentsSet)
            },
            emptyState: {
                EmptyRegionStateView(forContinents: true)
            }
        )
    }
}

// MARK: - Continent Map View (UIViewRepresentable)

/// Map that highlights visited continents using actual continent polygons
struct ContinentMapView: UIViewRepresentable {
    let visitedContinents: Set<Continent>
    let currentContinent: Continent?
    let centerCoordinate: CLLocationCoordinate2D
    let span: MKCoordinateSpan
    var onTap: ((CLLocationCoordinate2D) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = MKCoordinateRegion(center: centerCoordinate, span: span)
        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tapRecognizer)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap

        // Set the current continent BEFORE any rebuild so lazily-created renderers style correctly
        let previousContinent = coordinator.currentContinent
        coordinator.currentContinent = currentContinent

        // Rebuild only when the SET of visited continents changes; highlight changes
        // restyle the affected renderers in place (see RegionMapView for rationale)
        if coordinator.renderedContinents != visitedContinents {
            rebuildOverlays(on: mapView, coordinator: coordinator)
        } else if previousContinent != currentContinent {
            let continents = [previousContinent, currentContinent].compactMap { $0 }
            for continent in continents {
                if let overlay = coordinator.overlayByContinent[continent],
                   let renderer = mapView.renderer(for: overlay) as? MKOverlayPathRenderer {
                    Coordinator.applyStyle(to: renderer, isCurrent: continent == currentContinent)
                    renderer.setNeedsDisplay()
                }
            }
        }

        // Only move the camera when the target actually changed
        let target = MKCoordinateRegion(center: centerCoordinate, span: span)
        if !coordinator.isSameCameraTarget(target) {
            coordinator.lastCameraTarget = target
            mapView.setRegion(target, animated: true)
        }
    }

    private func rebuildOverlays(on mapView: MKMapView, coordinator: Coordinator) {
        mapView.removeOverlays(mapView.overlays)
        coordinator.overlayByContinent = [:]
        coordinator.renderedContinents = visitedContinents

        for continent in visitedContinents {
            let overlay = RegionOverlayCache.shared.multiPolygon(for: continent)
            coordinator.overlayByContinent[continent] = overlay
            mapView.addOverlay(overlay)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ContinentMapView
        var currentContinent: Continent?
        var onTap: ((CLLocationCoordinate2D) -> Void)?

        // Overlay bookkeeping for incremental updates (see updateUIView)
        var renderedContinents: Set<Continent> = []
        var overlayByContinent: [Continent: MKMultiPolygon] = [:]
        var lastCameraTarget: MKCoordinateRegion?

        init(_ parent: ContinentMapView) {
            self.parent = parent
            self.onTap = parent.onTap
        }

        func isSameCameraTarget(_ region: MKCoordinateRegion) -> Bool {
            guard let last = lastCameraTarget else { return false }
            return last.center.latitude == region.center.latitude &&
                   last.center.longitude == region.center.longitude &&
                   last.span.latitudeDelta == region.span.latitudeDelta &&
                   last.span.longitudeDelta == region.span.longitudeDelta
        }

        /// Single source of styling truth: used at renderer creation AND for in-place restyles
        static func applyStyle(to renderer: MKOverlayPathRenderer, isCurrent: Bool) {
            if isCurrent {
                // Current continent - red fill and stroke
                renderer.fillColor = UIColor.systemRed.withAlphaComponent(0.4)
                renderer.strokeColor = UIColor.systemRed
                renderer.lineWidth = 2
            } else {
                // Other visited continents - orange fill and stroke
                renderer.fillColor = UIColor.systemOrange.withAlphaComponent(0.3)
                renderer.strokeColor = UIColor.systemOrange
                renderer.lineWidth = 1
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            onTap?(coordinate)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multiPolygon = overlay as? MKMultiPolygon {
                let renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
                Self.applyStyle(to: renderer, isCurrent: multiPolygon.title == currentContinent?.rawValue)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Region Map View

/// Reusable map view for displaying visited regions with polygon overlays
struct RegionMapView: UIViewRepresentable {
    let regionType: RegionType
    let visitedRegions: [RecordDetail]
    let currentRegion: RecordDetail?
    let centerCoordinate: CLLocationCoordinate2D
    let span: MKCoordinateSpan
    var onTap: ((CLLocationCoordinate2D) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = MKCoordinateRegion(center: centerCoordinate, span: span)
        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tapRecognizer)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap

        // Set the current code BEFORE any rebuild so lazily-created renderers style correctly
        let previousCode = coordinator.currentRegionCode
        let newCode = currentRegion?.regionCode
        coordinator.currentRegionCode = newCode

        // Rebuild overlays only when the SET of visited regions changes. A change of
        // highlighted region restyles two renderers in place instead of re-tessellating
        // the entire overlay set (easily 100k+ vertices) on every tap or card swipe.
        let visitedCodes = visitedRegions.compactMap { $0.regionCode }
        if coordinator.renderedRegionCodes != visitedCodes {
            rebuildOverlays(on: mapView, coordinator: coordinator, visitedCodes: visitedCodes)
        } else if previousCode != newCode {
            let codes = [previousCode, newCode].compactMap { $0 }
            for code in codes {
                for polygon in coordinator.polygonsByCode[code] ?? [] {
                    if let renderer = mapView.renderer(for: polygon) as? MKPolygonRenderer {
                        Coordinator.applyStyle(to: renderer, isCurrent: code == newCode)
                        renderer.setNeedsDisplay()
                    }
                }
            }
        }

        // Only move the camera when the target actually changed: an unconditional
        // setRegion queued competing animations on every update and fought pan gestures
        let target = MKCoordinateRegion(center: centerCoordinate, span: span)
        if !coordinator.isSameCameraTarget(target) {
            coordinator.lastCameraTarget = target
            mapView.setRegion(target, animated: true)
        }
    }

    private func rebuildOverlays(on mapView: MKMapView, coordinator: Coordinator, visitedCodes: [String]) {
        mapView.removeOverlays(mapView.overlays)
        coordinator.polygonsByCode = [:]
        coordinator.renderedRegionCodes = visitedCodes

        // For states, add US outline first as base layer
        if regionType == .state {
            for polyline in RegionOverlayCache.shared.usOutlinePolylines() {
                mapView.addOverlay(polyline, level: .aboveLabels)
            }
        }

        // Add polygon overlays for visited regions (cached MKPolygons, built once per code)
        for detail in visitedRegions {
            guard let code = detail.regionCode else {
                debugLog("⚠️ RegionMapView: Missing regionCode for \(detail.locationName ?? "unknown")")
                continue
            }

            let polygons = RegionOverlayCache.shared.polygons(for: code, title: detail.locationName)
            if polygons.isEmpty {
                debugLog("⚠️ RegionMapView: No polygons found for code '\(code)' (\(detail.locationName ?? "unknown"))")
            }
            coordinator.polygonsByCode[code] = polygons
            for polygon in polygons {
                mapView.addOverlay(polygon, level: .aboveLabels)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RegionMapView
        var currentRegionCode: String?
        var onTap: ((CLLocationCoordinate2D) -> Void)?

        // Overlay bookkeeping for incremental updates (see updateUIView)
        var renderedRegionCodes: [String] = []
        var polygonsByCode: [String: [MKPolygon]] = [:]
        var lastCameraTarget: MKCoordinateRegion?

        init(_ parent: RegionMapView) {
            self.parent = parent
            self.onTap = parent.onTap
        }

        func isSameCameraTarget(_ region: MKCoordinateRegion) -> Bool {
            guard let last = lastCameraTarget else { return false }
            return last.center.latitude == region.center.latitude &&
                   last.center.longitude == region.center.longitude &&
                   last.span.latitudeDelta == region.span.latitudeDelta &&
                   last.span.longitudeDelta == region.span.longitudeDelta
        }

        /// Single source of styling truth: used at renderer creation AND for in-place restyles
        static func applyStyle(to renderer: MKPolygonRenderer, isCurrent: Bool) {
            if isCurrent {
                // Current region - red fill and stroke
                renderer.fillColor = UIColor.systemRed.withAlphaComponent(0.4)
                renderer.strokeColor = UIColor.systemRed
                renderer.lineWidth = 2
            } else {
                // Other visited regions - orange fill and stroke
                renderer.fillColor = UIColor.systemOrange.withAlphaComponent(0.3)
                renderer.strokeColor = UIColor.systemOrange
                renderer.lineWidth = 1
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            onTap?(coordinate)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                // US outline - subtle gray so only visited states stand out
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemGray3
                renderer.lineWidth = 0.5
                return renderer
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                Self.applyStyle(to: renderer, isCurrent: polygon.subtitle == currentRegionCode)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Styled Segmented Picker

/// Generic styled segmented picker that matches the Records page styling
struct StyledSegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = option
                    }
                } label: {
                    Text(label(option))
                        .font(.subheadline)
                        .fontWeight(selection == option ? .semibold : .regular)
                        .foregroundColor(selection == option ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            selection == option ? Color(UIColor.systemBackground) : Color.clear
                        )
                        .cornerRadius(6)
                        .padding(2)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(UIColor.systemGray5))
        .cornerRadius(8)
    }
}

// MARK: - Widget View Setter Sheet

/// Sheet for setting the widget map view by panning/zooming
struct WidgetViewSetterSheet: View {
    @State private var mapType: String  // "states", "countries", or "continents"
    private let passedRegions: [RecordDetail]
    private let passedContinents: Set<Continent>?
    /// From Settings: a map-type picker at the top, with the visited lists loaded here
    let allowsMapTypeChange: Bool

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var regionManager = RegionTrackingManager.shared
    @State private var mapRegion: MKCoordinateRegion
    @State private var showingSavedConfirmation = false

    private static let mapTypes = ["states", "countries", "continents"]

    init(mapType: String, visitedRegions: [RecordDetail], visitedContinents: Set<Continent>? = nil, allowsMapTypeChange: Bool = false) {
        _mapType = State(initialValue: mapType)
        self.passedRegions = visitedRegions
        self.passedContinents = visitedContinents
        self.allowsMapTypeChange = allowsMapTypeChange
        _mapRegion = State(initialValue: Self.savedOrDefaultRegion(for: mapType))
    }

    /// The saved framing for a map type, else a sensible default
    private static func savedOrDefaultRegion(for mapType: String) -> MKCoordinateRegion {
        let settings = SettingsManager.shared
        let savedRegion: MKCoordinateRegion?
        switch mapType {
        case "states":
            savedRegion = settings.widgetMapStatesRegion
        case "countries":
            savedRegion = settings.widgetMapCountriesRegion
        case "continents":
            savedRegion = settings.widgetMapContinentsRegion
        default:
            savedRegion = nil
        }
        if let saved = savedRegion { return saved }

        switch mapType {
        case "states":
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 45, longitude: -120),
                span: MKCoordinateSpan(latitudeDelta: 75, longitudeDelta: 100)
            )
        default:
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 280)
            )
        }
    }

    private var visitedRegions: [RecordDetail] {
        guard allowsMapTypeChange else { return passedRegions }
        let regions: [RecordDetail]
        switch mapType {
        case "states": regions = regionManager.visitedStates
        case "countries": regions = regionManager.visitedCountries
        default: regions = regionManager.visitedContinents
        }
        return regions.sorted { ($0.locationName ?? "") < ($1.locationName ?? "") }
    }

    private var visitedContinents: Set<Continent>? {
        guard allowsMapTypeChange else { return passedContinents }
        guard mapType == "continents" else { return nil }
        return Set(regionManager.visitedContinents.compactMap { Continent(rawValue: $0.locationName ?? "") })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if allowsMapTypeChange {
                    Picker("Map", selection: $mapType) {
                        Text("States").tag("states")
                        Text("Countries").tag("countries")
                        Text("Continents").tag("continents")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .onChange(of: mapType) { _, newType in
                        mapRegion = Self.savedOrDefaultRegion(for: newType)
                    }
                }

                // Instructions
                Text("Pan and zoom to set the widget map view")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)

                // Interactive map with aspect ratio matching widget (recreated per map type)
                InteractiveWidgetMapView(
                    mapType: mapType,
                    visitedRegions: visitedRegions,
                    visitedContinents: visitedContinents,
                    region: $mapRegion
                )
                .id(mapType)
                .aspectRatio(mapAspectRatio, contentMode: .fit)
                .cornerRadius(12)
                .padding(.horizontal)

                // Current region info
                VStack(spacing: 4) {
                    Text("Center: \(String(format: "%.2f", mapRegion.center.latitude))°, \(String(format: "%.2f", mapRegion.center.longitude))°")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Span: \(String(format: "%.1f", mapRegion.span.latitudeDelta))° × \(String(format: "%.1f", mapRegion.span.longitudeDelta))°")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)

                // Clear button if custom region exists
                if hasCustomRegion {
                    Button(role: .destructive) {
                        SettingsManager.shared.clearWidgetMapRegion(for: mapType)
                        Task {
                            await WidgetMapGenerator.shared.generateMap(for: widgetMapType)
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                        dismiss()
                    } label: {
                        Label("Reset to Default", systemImage: "arrow.counterclockwise")
                    }
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("Set Widget View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveWidgetView()
                    }
                }
            }
            .overlay {
                if showingSavedConfirmation {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Widget view saved!")
                        }
                        .padding()
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(10)
                        .shadow(radius: 5)
                        .padding(.bottom, 100)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var hasCustomRegion: Bool {
        let settings = SettingsManager.shared
        switch mapType {
        case "states":
            return settings.widgetMapStatesRegion != nil
        case "countries":
            return settings.widgetMapCountriesRegion != nil
        case "continents":
            return settings.widgetMapContinentsRegion != nil
        default:
            return false
        }
    }

    /// Aspect ratio matching the widget map image size (from Constants.swift)
    private var mapAspectRatio: CGFloat {
        return widgetMapAspectRatio
    }

    private var widgetMapType: WidgetMapGenerator.MapType {
        switch mapType {
        case "states": return .states
        case "countries": return .countries
        case "continents": return .continents
        default: return .states
        }
    }

    private func saveWidgetView() {
        SettingsManager.shared.setWidgetMapRegion(mapRegion, for: mapType)

        // Regenerate the widget map with the new region
        Task {
            await WidgetMapGenerator.shared.generateMap(for: widgetMapType)
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Show confirmation
        withAnimation {
            showingSavedConfirmation = true
        }

        // Dismiss after a short delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            dismiss()
        }
    }
}

// MARK: - Interactive Widget Map View

/// Map view that allows user interaction for setting widget view
struct InteractiveWidgetMapView: UIViewRepresentable {
    let mapType: String
    let visitedRegions: [RecordDetail]
    let visitedContinents: Set<Continent>?
    @Binding var region: MKCoordinateRegion

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = region
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Only update overlays, don't change region (user controls that)
        if context.coordinator.needsOverlayUpdate {
            mapView.removeOverlays(mapView.overlays)
            addOverlays(to: mapView)
            context.coordinator.needsOverlayUpdate = false
        }
    }

    private func addOverlays(to mapView: MKMapView) {
        if let continents = visitedContinents {
            // Continent mode: one multipolygon overlay per continent
            for continent in continents {
                mapView.addOverlay(RegionOverlayCache.shared.multiPolygon(for: continent))
            }
        } else {
            // States/Countries mode (the cached polygons carry their holes)
            for detail in visitedRegions {
                guard let code = detail.regionCode else { continue }
                mapView.addOverlays(RegionOverlayCache.shared.polygons(for: code, title: detail.locationName))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: InteractiveWidgetMapView
        var needsOverlayUpdate = true

        init(_ parent: InteractiveWidgetMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Update the binding when user changes the region
            DispatchQueue.main.async {
                self.parent.region = mapView.region
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer: MKOverlayPathRenderer
            if let polygon = overlay as? MKPolygon {
                renderer = MKPolygonRenderer(polygon: polygon)
            } else if let multiPolygon = overlay as? MKMultiPolygon {
                renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let color: UIColor
            switch parent.mapType {
            case "states":
                color = .systemBlue
            case "countries":
                color = .systemGreen
            case "continents":
                color = .systemOrange
            default:
                color = .systemBlue
            }
            renderer.fillColor = color.withAlphaComponent(0.4)
            renderer.strokeColor = color
            renderer.lineWidth = 1
            return renderer
        }
    }
}

// MARK: - Preview

#Preview {
    MapsTabView()
}
