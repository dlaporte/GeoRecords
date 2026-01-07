import SwiftUI
import MapKit

// MARK: - Maps Tab View

/// Container view for the Maps tab with segmented picker for States/Countries/Continents
struct MapsTabView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared
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
        }
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

// MARK: - States Map View

/// Shows visited US states as cards
struct StatesMapView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared
    @State private var currentCardIndex = 0
    @State private var selectedDetail: RecordDetail?
    @State private var navigateToDetail = false

    // Sorted states alphabetically by name
    private var sortedStates: [RecordDetail] {
        regionManager.visitedStates.sorted { ($0.locationName ?? "") < ($1.locationName ?? "") }
    }

    // Current region to display on map
    private var currentRegion: RecordDetail? {
        guard !sortedStates.isEmpty,
              currentCardIndex < sortedStates.count else {
            return nil
        }
        return sortedStates[currentCardIndex]
    }

    // Map region for current card (center and span)
    private var mapRegion: (center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        guard let region = currentRegion, let code = region.regionCode else {
            let defaultRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
                span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 10)
            )
            return (defaultRegion.center, defaultRegion.span)
        }

        let polygonArrays = RegionLookupService.shared.polygons(for: code)
        let calculatedRegion = calculateMapRegion(
            for: polygonArrays,
            defaultRegion: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
                span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 10)
            )
        )
        return (calculatedRegion.center, calculatedRegion.span)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Map showing current state with overlaid stats
            ZStack(alignment: .top) {
                RegionMapView(
                    regionType: .state,
                    visitedRegions: sortedStates,
                    currentRegion: currentRegion,
                    centerCoordinate: mapRegion.center,
                    span: mapRegion.span
                )
                .frame(maxWidth: .infinity)

                // Stats header overlaid on map
                HStack {
                    Image(systemName: "flag.fill")
                        .foregroundColor(.orange)
                    Text("\(regionManager.stateCount) of 50 states visited")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemBackground).opacity(0.9))
                .cornerRadius(8)
                .padding(.top, 12)
            }

            // Cards
            if sortedStates.isEmpty {
                Spacer()
                EmptyRegionStateView(regionType: .state)
                Spacer()
            } else {
                TabView(selection: $currentCardIndex) {
                    ForEach(Array(sortedStates.enumerated()), id: \.element.id) { index, detail in
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
                .frame(height: 280)
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

// MARK: - Countries Map View

/// Shows visited countries as cards
struct CountriesMapView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared
    @State private var currentCardIndex = 0
    @State private var selectedDetail: RecordDetail?
    @State private var navigateToDetail = false

    // Sorted countries alphabetically by name
    private var sortedCountries: [RecordDetail] {
        regionManager.visitedCountries.sorted { ($0.locationName ?? "") < ($1.locationName ?? "") }
    }

    // Current region to display on map
    private var currentRegion: RecordDetail? {
        guard !sortedCountries.isEmpty,
              currentCardIndex < sortedCountries.count else {
            return nil
        }
        return sortedCountries[currentCardIndex]
    }

    // Map region for current card (center and span)
    private var mapRegion: (center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        guard let region = currentRegion, let code = region.regionCode else {
            let defaultRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 15, longitudeDelta: 20)
            )
            return (defaultRegion.center, defaultRegion.span)
        }

        let polygonArrays = RegionLookupService.shared.polygons(for: code)
        let calculatedRegion = calculateMapRegion(
            for: polygonArrays,
            defaultRegion: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 15, longitudeDelta: 20)
            )
        )
        return (calculatedRegion.center, calculatedRegion.span)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Map showing current country with overlaid stats
            ZStack(alignment: .top) {
                RegionMapView(
                    regionType: .country,
                    visitedRegions: sortedCountries,
                    currentRegion: currentRegion,
                    centerCoordinate: mapRegion.center,
                    span: mapRegion.span
                )
                .frame(maxWidth: .infinity)

                // Stats header overlaid on map
                HStack {
                    Image(systemName: "globe.americas.fill")
                        .foregroundColor(.blue)
                    Text("\(regionManager.countryCount) of 195 countries visited")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemBackground).opacity(0.9))
                .cornerRadius(8)
                .padding(.top, 12)
            }

            // Cards
            if sortedCountries.isEmpty {
                Spacer()
                EmptyRegionStateView(regionType: .country)
                Spacer()
            } else {
                TabView(selection: $currentCardIndex) {
                    ForEach(Array(sortedCountries.enumerated()), id: \.element.id) { index, detail in
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
                .frame(height: 280)
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

// MARK: - Continents Map View

/// Shows visited continents as cards
struct ContinentsMapView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared
    @State private var currentCardIndex = 0
    @State private var selectedDetail: RecordDetail?
    @State private var navigateToDetail = false

    // Sorted continents alphabetically by name
    private var sortedContinents: [RecordDetail] {
        regionManager.visitedContinents.sorted { ($0.locationName ?? "") < ($1.locationName ?? "") }
    }

    // Current region to display on map
    private var currentRegion: RecordDetail? {
        guard !sortedContinents.isEmpty,
              currentCardIndex < sortedContinents.count else {
            return nil
        }
        return sortedContinents[currentCardIndex]
    }

    // Map region for current card (center and span based on continent bounds)
    private var mapRegion: (center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        guard let region = currentRegion,
              let continent = Continent(rawValue: region.locationName ?? "") else {
            let defaultRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 80)
            )
            return (defaultRegion.center, defaultRegion.span)
        }

        let polygonArrays = RegionLookupService.shared.continentPolygons(for: continent)
        let calculatedRegion = calculateMapRegion(
            for: polygonArrays,
            padding: 1.3,  // 30% padding for continents
            minSpan: 5.0,  // Larger minimum span for continents
            defaultRegion: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 80)
            )
        )
        return (calculatedRegion.center, calculatedRegion.span)
    }

    private var visitedContinentsSet: Set<Continent> {
        Set(sortedContinents.compactMap { Continent(rawValue: $0.locationName ?? "") })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Map showing current continent with overlaid stats
            ZStack(alignment: .top) {
                ContinentMapView(
                    visitedContinents: visitedContinentsSet,
                    currentContinent: currentRegion.flatMap { Continent(rawValue: $0.locationName ?? "") },
                    centerCoordinate: mapRegion.center,
                    span: mapRegion.span
                )
                .frame(maxWidth: .infinity)

                // Stats header overlaid on map
                HStack {
                    Image(systemName: "globe")
                        .foregroundColor(.purple)
                    Text("\(regionManager.continentCount) of 7 continents visited")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemBackground).opacity(0.9))
                .cornerRadius(8)
                .padding(.top, 12)
            }

            // Cards
            if sortedContinents.isEmpty {
                Spacer()
                EmptyRegionStateView(forContinents: true)
                Spacer()
            } else {
                TabView(selection: $currentCardIndex) {
                    ForEach(Array(sortedContinents.enumerated()), id: \.element.id) { index, detail in
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
                .frame(height: 280)
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

// MARK: - Continent Map View (UIViewRepresentable)

/// Map that highlights visited continents using actual continent polygons
struct ContinentMapView: UIViewRepresentable {
    let visitedContinents: Set<Continent>
    let currentContinent: Continent?
    let centerCoordinate: CLLocationCoordinate2D
    let span: MKCoordinateSpan

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = MKCoordinateRegion(center: centerCoordinate, span: span)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update coordinator with current continent
        context.coordinator.currentContinent = currentContinent

        // Remove existing overlays
        mapView.removeOverlays(mapView.overlays)

        // Add polygon overlays for visited continents
        for continent in visitedContinents {
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

        // Update map region to center on current coordinate
        mapView.setRegion(MKCoordinateRegion(center: centerCoordinate, span: span), animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ContinentMapView
        var currentContinent: Continent?

        init(_ parent: ContinentMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)

                // Check if this is the current continent
                let isCurrent = polygon.title == currentContinent?.rawValue

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

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = MKCoordinateRegion(center: centerCoordinate, span: span)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update coordinator with current region code
        context.coordinator.currentRegionCode = currentRegion?.regionCode

        // Remove existing overlays
        mapView.removeOverlays(mapView.overlays)

        // For states, add US outline first as base layer
        if regionType == .state {
            let outlinePolylines = RegionLookupService.shared.getUSOutlinePolylines()
            for coordinates in outlinePolylines {
                guard coordinates.count > 1 else { continue }
                var coords = coordinates
                let polyline = MKPolyline(coordinates: &coords, count: coords.count)
                polyline.title = "outline"
                mapView.addOverlay(polyline, level: .aboveLabels)
            }
        }

        // Add polygon overlays for visited regions
        for detail in visitedRegions {
            guard let code = detail.regionCode else {
                debugLog("⚠️ RegionMapView: Missing regionCode for \(detail.locationName ?? "unknown")")
                continue
            }

            let polygonArrays = RegionLookupService.shared.polygons(for: code)
            if polygonArrays.isEmpty {
                debugLog("⚠️ RegionMapView: No polygons found for code '\(code)' (\(detail.locationName ?? "unknown"))")
            } else {
                debugLog("📍 RegionMapView: Adding \(polygonArrays.count) polygon groups for '\(code)' (\(detail.locationName ?? "unknown"))")
            }
            for polygonGroup in polygonArrays {
                for coordinates in polygonGroup {
                    guard coordinates.count > 2 else { continue }
                    var coords = coordinates
                    let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                    polygon.title = detail.locationName
                    polygon.subtitle = code
                    mapView.addOverlay(polygon, level: .aboveLabels)
                }
            }
        }

        // Update map region to center on current coordinate
        mapView.setRegion(MKCoordinateRegion(center: centerCoordinate, span: span), animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RegionMapView
        var currentRegionCode: String?

        init(_ parent: RegionMapView) {
            self.parent = parent
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

                // Check if this is the current region
                let isCurrent = polygon.subtitle == currentRegionCode

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

// MARK: - Preview

#Preview {
    MapsTabView()
}
