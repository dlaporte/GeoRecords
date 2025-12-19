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
                Picker("Map Type", selection: $selectedMapType) {
                    ForEach(MapType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                // Map content
                Group {
                    switch selectedMapType {
                    case .states:
                        StatesMapView()
                    case .countries:
                        CountriesMapView()
                    case .continents:
                        ContinentsMapView()
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: selectedMapType)
            }
            .navigationTitle("Maps")
        }
    }
}

// MARK: - States Map View

/// Map showing visited US states
struct StatesMapView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared

    /// All 50 states sorted alphabetically with visit info
    private var allStatesWithVisitInfo: [(state: RegionInfo, visitDate: Date?)] {
        // Build dictionary, keeping earliest date for duplicates
        var visitedCodes: [String: Date] = [:]
        for region in regionManager.visitedStates {
            guard let code = region.regionCode,
                  let date = region.firstVisitDate else { continue }
            if let existing = visitedCodes[code] {
                visitedCodes[code] = min(existing, date)
            } else {
                visitedCodes[code] = date
            }
        }

        return RegionLookupService.shared.allUSStates
            .sorted { $0.name < $1.name }
            .map { state in
                (state: state, visitDate: visitedCodes[state.code])
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stats header
            HStack {
                Image(systemName: "flag.fill")
                    .foregroundColor(.blue)
                Text("\(regionManager.stateCount) of 50 states visited")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)

            // Map
            RegionMapView(
                regionType: .state,
                visitedRegions: regionManager.visitedStates,
                centerCoordinate: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
                span: MKCoordinateSpan(latitudeDelta: 45, longitudeDelta: 60)
            )
            .frame(height: 280)

            // List of all states
            List {
                ForEach(allStatesWithVisitInfo, id: \.state.code) { item in
                    HStack {
                        Text(item.state.name)
                            .font(.body)
                            .foregroundColor(item.visitDate != nil ? .primary : .secondary)
                        Spacer()
                        if let visitDate = item.visitDate {
                            Text(visitDate, style: .date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("–")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Countries Map View

/// Map showing visited countries
struct CountriesMapView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared

    /// Countries grouped by continent
    private var countriesByContinent: [(continent: String, countries: [VisitedRegion])] {
        var grouped: [String: [VisitedRegion]] = [:]

        for country in regionManager.visitedCountries {
            let continentName = getContinentName(for: country.regionCode ?? "")
            grouped[continentName, default: []].append(country)
        }

        // Sort continents alphabetically, then countries within each
        return grouped.keys.sorted().map { continent in
            let sortedCountries = grouped[continent]!.sorted { ($0.regionName ?? "") < ($1.regionName ?? "") }
            return (continent: continent, countries: sortedCountries)
        }
    }

    private func getContinentName(for countryCode: String) -> String {
        for country in RegionLookupService.shared.allCountries {
            if country.code == countryCode {
                return country.continent?.rawValue ?? "Other"
            }
        }
        return "Other"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stats header
            HStack {
                Image(systemName: "globe.americas.fill")
                    .foregroundColor(.blue)
                Text("\(regionManager.countryCount) of 195 countries visited")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)

            // Map
            RegionMapView(
                regionType: .country,
                visitedRegions: regionManager.visitedCountries,
                centerCoordinate: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
            )
            .frame(height: 280)

            // List of visited countries grouped by continent
            if regionManager.visitedCountries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "globe")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No countries visited yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(countriesByContinent, id: \.continent) { group in
                        Section(header: Text(group.continent)) {
                            ForEach(group.countries, id: \.regionCode) { country in
                                HStack {
                                    Text(country.regionName ?? "Unknown")
                                        .font(.body)
                                    Spacer()
                                    if let firstVisit = country.firstVisitDate {
                                        Text(firstVisit, style: .date)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Continents Map View

/// Map showing visited continents (derived from countries)
struct ContinentsMapView: View {
    @StateObject private var regionManager = RegionTrackingManager.shared

    private var visitedContinents: Set<Continent> {
        regionManager.getVisitedContinents()
    }

    /// All continents with their visited country counts
    private var continentStats: [(continent: Continent, visitedCount: Int, totalCount: Int, isVisited: Bool)] {
        let allCountries = RegionLookupService.shared.allCountries
        let visitedCodes = Set(regionManager.visitedCountries.compactMap { $0.regionCode })

        return Continent.allCases.map { continent in
            let countriesInContinent = allCountries.filter { $0.continent == continent }
            let visitedInContinent = countriesInContinent.filter { visitedCodes.contains($0.code) }
            return (
                continent: continent,
                visitedCount: visitedInContinent.count,
                totalCount: countriesInContinent.count,
                isVisited: visitedInContinent.count > 0
            )
        }.sorted { $0.continent.rawValue < $1.continent.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stats header
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(.blue)
                Text("\(visitedContinents.count) of 7 continents visited")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)

            // Map showing visited continents
            ContinentMapView(
                visitedContinents: visitedContinents,
                centerCoordinate: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
            )
            .frame(height: 280)

            // List of all continents
            List {
                ForEach(continentStats, id: \.continent) { stat in
                    HStack {
                        Image(systemName: stat.isVisited ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(stat.isVisited ? .blue : .secondary.opacity(0.3))
                            .font(.title3)

                        Text(stat.continent.rawValue)
                            .font(.body)
                            .foregroundColor(stat.isVisited ? .primary : .secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Continent Map View (UIViewRepresentable)

/// Map that highlights visited continents using actual continent polygons
struct ContinentMapView: UIViewRepresentable {
    let visitedContinents: Set<Continent>
    let centerCoordinate: CLLocationCoordinate2D
    let span: MKCoordinateSpan

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = MKCoordinateRegion(center: centerCoordinate, span: span)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ContinentMapView

        init(_ parent: ContinentMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.3)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 1
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
    let visitedRegions: [VisitedRegion]
    let centerCoordinate: CLLocationCoordinate2D
    let span: MKCoordinateSpan

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = MKCoordinateRegion(center: centerCoordinate, span: span)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
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
        for region in visitedRegions {
            guard let code = region.regionCode else { continue }

            let polygonArrays = RegionLookupService.shared.polygons(for: code)
            for polygonGroup in polygonArrays {
                for coordinates in polygonGroup {
                    guard coordinates.count > 2 else { continue }
                    var coords = coordinates
                    let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                    polygon.title = region.regionName
                    polygon.subtitle = code
                    mapView.addOverlay(polygon, level: .aboveLabels)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RegionMapView

        init(_ parent: RegionMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                // US outline - blue stroke to match state overlays
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 1
                return renderer
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.3)
                renderer.strokeColor = UIColor.systemBlue
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
