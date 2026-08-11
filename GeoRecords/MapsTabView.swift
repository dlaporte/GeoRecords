import SwiftUI
import MapKit
import WidgetKit

// MARK: - Maps Tab View

/// Container view for the Maps tab with segmented picker for States/Countries/Continents
struct MapsTabView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared
    @EnvironmentObject private var deepLinkManager: DeepLinkManager
    @State private var selectedMapType: MapType = .states

    enum MapType: String, CaseIterable {
        case states = "States"
        case countries = "Countries"
        case continents = "Continents"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented picker
                StyledSegmentedPicker(
                    selection: $selectedMapType,
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

                // Map content
                switch selectedMapType {
                case .states:
                    StatesMapView()
                case .countries:
                    CountriesMapView()
                case .continents:
                    ContinentsMapView()
                }
            }
            .navigationTitle("Regions")
            .onAppear {
                handleDeepLink()
            }
            .onChange(of: deepLinkManager.navigateToRegions) { _, _ in
                handleDeepLink()
            }
        }
    }

    private func handleDeepLink() {
        guard let section = deepLinkManager.navigateToRegions else { return }
        switch section {
        case "states":
            selectedMapType = .states
        case "countries":
            selectedMapType = .countries
        case "continents":
            selectedMapType = .continents
        default:
            break
        }
        deepLinkManager.navigateToRegions = nil
    }
}

// MARK: - Pending Regions Banner

/// Compact confirmation list for regions discovered by the automatic photo catch-up.
/// Confirming records the visit through the normal path; dismissing forgets it.
private struct PendingRegionsBanner: View {
    @ObservedObject var regionManager: RegionTrackingManager

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
                        withAnimation {
                            regionManager.confirmPendingRegion(code: pending.code)
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
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
    }
}

// MARK: - Visited Region Card Component

struct VisitedRegionCard: View {
    let detail: RecordDetail
    @EnvironmentObject var settings: SettingsManager

    private let sizing = CardSizing()

    var body: some View {
        VStack(alignment: .leading, spacing: sizing.cardSpacing) {
            // Header with icon and region info
            HStack(spacing: sizing.isCompact ? 8 : 12) {
                Image(systemName: FormatUtils.iconForRecordType(detail.recordType))
                    .font(sizing.isCompact ? .title3 : .title)
                    .foregroundColor(FormatUtils.colorForRecordType(detail.recordType))
                    .frame(width: sizing.iconSize, height: sizing.iconSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.recordType)
                        .font(sizing.isCompact ? .caption : .headline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(detail.locationName ?? "Unknown")
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
                // Left side - region name and details
                VStack(alignment: .leading, spacing: sizing.contentSpacing) {
                    // Region name as the "value"
                    VStack(alignment: .leading, spacing: sizing.isCompact ? 2 : 4) {
                        if !sizing.isCompact {
                            Text("Region")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 6) {
                            if let flag = FormatUtils.flagEmoji(for: detail.regionCode, recordType: detail.recordType) {
                                Text(flag)
                                    .font(.system(size: sizing.isCompact ? 18 : 24))
                            }
                            Text(detail.locationName ?? "Unknown")
                                .font(.system(size: sizing.isCompact ? 20 : 28, weight: .bold, design: .default))
                                .foregroundColor(FormatUtils.colorForRecordType(detail.recordType))
                                .minimumScaleFactor(0.7)
                                .lineLimit(2)
                        }
                    }

                    // First visit date
                    if !sizing.isCompact {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("First Visit")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(detail.timestamp, style: .date)
                                .font(.subheadline)
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
        .onAppear {
            if detail.photoAssetIdentifier != nil || detail.photoData != nil {
                debugLog("📸 Region card '\(detail.locationName ?? "Unknown")' has photo - localId: \(detail.photoAssetIdentifier ?? "nil"), cloudId: \(detail.photoCloudIdentifier ?? "nil")")
            } else {
                debugLog("📸 Region card '\(detail.locationName ?? "Unknown")' has NO photo identifier")
            }
        }
    }

}

// MARK: - Shared Region Cards + Map Layout

/// Shared layout for the three region tabs (states/countries/continents):
/// a map with a stats-header overlay and widget button, above swipeable region cards.
/// The tab-specific pieces (map view, region math, sheet, empty state) come in as
/// closures; everything else previously existed as three ~105-line verbatim copies.
private struct RegionCardsMapView<MapV: View, SheetV: View, EmptyV: View>: View {
    let regions: [RecordDetail]
    let statsIcon: String
    let statsIconColor: Color
    let statsText: String
    let widgetButtonHighlighted: Bool
    /// Maps a tapped map coordinate to the index of the matching card (nil = no card)
    let cardIndex: (CLLocationCoordinate2D) -> Int?
    @ViewBuilder let mapView: (RecordDetail?, _ onTap: @escaping (CLLocationCoordinate2D) -> Void) -> MapV
    @ViewBuilder let widgetSheet: () -> SheetV
    @ViewBuilder let emptyState: () -> EmptyV

    @State private var currentCardIndex = 0
    @State private var selectedDetail: RecordDetail?
    @State private var navigateToDetail = false
    @State private var showWidgetViewSetter = false

    // Current region to display on map
    private var currentRegion: RecordDetail? {
        guard !regions.isEmpty, currentCardIndex < regions.count else {
            return nil
        }
        return regions[currentCardIndex]
    }

    // Tapping a visited region on the map swipes the card carousel to it
    private func selectCard(at coordinate: CLLocationCoordinate2D) {
        guard let index = cardIndex(coordinate) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentCardIndex = index
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Map showing current region with overlaid stats
            ZStack(alignment: .top) {
                mapView(currentRegion, selectCard)
                    .frame(maxWidth: .infinity)

                // Stats header overlaid on map
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemBackground).opacity(0.9))
                .cornerRadius(8)
                .padding(.top, 12)
                .padding(.horizontal, 12)
            }
            .sheet(isPresented: $showWidgetViewSetter) {
                widgetSheet()
            }

            // Cards
            if regions.isEmpty {
                Spacer()
                emptyState()
                Spacer()
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
                .frame(maxWidth: .infinity)
                .frame(height: cardTabViewHeight)
                .padding(.vertical, 10)
                .navigationDestination(isPresented: $navigateToDetail) {
                    if let detail = selectedDetail {
                        RecordDetailView(record: detail)
                    }
                }
            }
        }
    }
}

// MARK: - States Map View

/// Shows visited US states as cards
struct StatesMapView: View {
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
        RegionCardsMapView(
            regions: sortedStates,
            statsIcon: "flag.fill",
            statsIconColor: .orange,
            statsText: "\(regionManager.stateCount) of 50 states visited",
            widgetButtonHighlighted: SettingsManager.shared.widgetMapStatesRegion != nil,
            cardIndex: { coordinate in
                guard let info = RegionLookupService.shared.region(for: coordinate),
                      info.type == .state else { return nil }
                return sortedStates.firstIndex { $0.regionCode == info.code }
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
        RegionCardsMapView(
            regions: sortedCountries,
            statsIcon: "globe.americas.fill",
            statsIconColor: .blue,
            statsText: "\(regionManager.countryCount) of 195 countries visited",
            widgetButtonHighlighted: SettingsManager.shared.widgetMapCountriesRegion != nil,
            cardIndex: { coordinate in
                guard let info = RegionLookupService.shared.region(for: coordinate) else { return nil }
                // A tap on a US state should select the United States card
                let countryCode = info.type == .state ? "US" : info.code
                return sortedCountries.firstIndex { $0.regionCode == countryCode }
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
        RegionCardsMapView(
            regions: sortedContinents,
            statsIcon: "globe",
            statsIconColor: .purple,
            statsText: "\(regionManager.continentCount) of 7 continents visited",
            widgetButtonHighlighted: SettingsManager.shared.widgetMapContinentsRegion != nil,
            cardIndex: { coordinate in
                guard let continent = RegionLookupService.shared.region(for: coordinate)?.continent else { return nil }
                return sortedContinents.firstIndex { Continent(rawValue: $0.locationName ?? "") == continent }
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
            for continent in [previousContinent, currentContinent].compactMap({ $0 }) {
                for polygon in coordinator.polygonsByContinent[continent] ?? [] {
                    if let renderer = mapView.renderer(for: polygon) as? MKPolygonRenderer {
                        Coordinator.applyStyle(to: renderer, isCurrent: continent == currentContinent)
                        renderer.setNeedsDisplay()
                    }
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
        coordinator.polygonsByContinent = [:]
        coordinator.renderedContinents = visitedContinents

        for continent in visitedContinents {
            let polygons = RegionOverlayCache.shared.polygons(for: continent)
            coordinator.polygonsByContinent[continent] = polygons
            for polygon in polygons {
                mapView.addOverlay(polygon)
            }
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
        var polygonsByContinent: [Continent: [MKPolygon]] = [:]
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
        static func applyStyle(to renderer: MKPolygonRenderer, isCurrent: Bool) {
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
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                Self.applyStyle(to: renderer, isCurrent: polygon.title == currentContinent?.rawValue)
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
            for code in [previousCode, newCode].compactMap({ $0 }) {
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
private struct StyledSegmentedPicker<T: Hashable>: View {
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
    let mapType: String  // "states", "countries", or "continents"
    let visitedRegions: [RecordDetail]
    var visitedContinents: Set<Continent>? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var mapRegion: MKCoordinateRegion
    @State private var showingSavedConfirmation = false

    init(mapType: String, visitedRegions: [RecordDetail], visitedContinents: Set<Continent>? = nil) {
        self.mapType = mapType
        self.visitedRegions = visitedRegions
        self.visitedContinents = visitedContinents

        // Initialize with saved region or default
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

        // Use saved region or fallback to defaults
        if let saved = savedRegion {
            _mapRegion = State(initialValue: saved)
        } else {
            let defaultRegion: MKCoordinateRegion
            switch mapType {
            case "states":
                defaultRegion = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 45, longitude: -120),
                    span: MKCoordinateSpan(latitudeDelta: 75, longitudeDelta: 100)
                )
            default:
                defaultRegion = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                    span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 280)
                )
            }
            _mapRegion = State(initialValue: defaultRegion)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Instructions
                Text("Pan and zoom to set the widget map view")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)

                // Interactive map with aspect ratio matching widget
                InteractiveWidgetMapView(
                    mapType: mapType,
                    visitedRegions: visitedRegions,
                    visitedContinents: visitedContinents,
                    region: $mapRegion
                )
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
            // Continent mode
            for continent in continents {
                let polygonArrays = RegionLookupService.shared.continentPolygons(for: continent)
                for polygonGroup in polygonArrays {
                    for coordinates in polygonGroup {
                        guard coordinates.count > 2 else { continue }
                        var coords = coordinates
                        let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                        polygon.title = continent.rawValue
                        mapView.addOverlay(polygon)
                    }
                }
            }
        } else {
            // States/Countries mode
            for detail in visitedRegions {
                guard let code = detail.regionCode else { continue }
                let polygonArrays = RegionLookupService.shared.polygons(for: code)
                for polygonGroup in polygonArrays {
                    for coordinates in polygonGroup {
                        guard coordinates.count > 2 else { continue }
                        var coords = coordinates
                        let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                        polygon.title = detail.locationName
                        mapView.addOverlay(polygon)
                    }
                }
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
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
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
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Preview

#Preview {
    MapsTabView()
}
