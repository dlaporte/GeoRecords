import SwiftUI
import MapKit
import CoreLocation

struct HomePickerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var locationManager: LocationManager

    @State private var position: MapCameraPosition
    @State private var currentCoordinate: CLLocationCoordinate2D
    @State private var showLocationUnavailableAlert = false
    @State private var locationName: String?
    @State private var isGeocoding = false

    init() {
        let defaultCoord = CLLocationCoordinate2D(latitude: 38.897957, longitude: -77.036560)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: defaultCoord,
            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
        )))
        _currentCoordinate = State(initialValue: defaultCoord)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Map takes available space
            MapReader { reader in
                Map(position: $position) {
                    Marker("Home", coordinate: currentCoordinate)
                        .tint(.red)
                }
                .overlay(alignment: .top) {
                    // Hint text overlay
                    Text("Tap map to select location")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(16)
                        .padding(.top, 12)
                }
                .onTapGesture { position in
                    if let coordinate = reader.convert(position, from: .local) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentCoordinate = coordinate
                        }
                        geocodeCoordinate(coordinate)
                    }
                }
            }
            .frame(minHeight: 300)

            // Bottom section with location info and buttons
            VStack(spacing: 16) {
                // Selected Location Card
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Selected Location")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if isGeocoding {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Looking up address...")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            } else if let name = locationName {
                                Text(name)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(2)
                            } else {
                                Text("Unknown Location")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }

                    // Coordinates
                    HStack {
                        Text(FormatUtils.formatCoordinatesWithCardinals(currentCoordinate))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fontDesign(.monospaced)

                        Spacer()
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemBackground))
                )

                // Use Current Location Button (secondary style)
                Button(action: useCurrentLocation) {
                    HStack {
                        Image(systemName: "location.fill")
                        Text("Use Current Location")
                    }
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.blue)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue, lineWidth: 2)
                    )
                }

                // Set Home Location Button (primary style)
                Button(action: setHomeLocation) {
                    Text("Set Home Location")
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundColor(.white)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
            }
            .padding()
            .background(Color(UIColor.systemBackground))
        }
        .navigationTitle("Select Home Location")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Location Unavailable", isPresented: $showLocationUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We could not determine your current location. Please ensure Location Services are enabled and try again.")
        }
        .onAppear {
            initializeFromSettings()
        }
    }

    // MARK: - Actions

    private func useCurrentLocation() {
        if let currentLocation = locationManager.currentLocation {
            debugLog("Using current location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)")
            withAnimation(.easeInOut(duration: 0.3)) {
                currentCoordinate = currentLocation.coordinate
                position = .region(MKCoordinateRegion(
                    center: currentLocation.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
                ))
            }
            geocodeCoordinate(currentLocation.coordinate)
        } else {
            debugLog("No current location available!")
            showLocationUnavailableAlert = true
        }
    }

    private func setHomeLocation() {
        settings.homeCoordinate = currentCoordinate
        settings.homeLocationName = locationName
        settings.saveSettings()

        // Create region records for the home location (state, country, continent)
        RegionTrackingManager.shared.addHomeRegionRecords()

        dismiss()
    }

    private func initializeFromSettings() {
        if let homeCoord = settings.homeCoordinate {
            currentCoordinate = homeCoord
            position = .region(MKCoordinateRegion(
                center: homeCoord,
                span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
            ))
            if let existingName = settings.homeLocationName {
                locationName = existingName
            } else {
                geocodeCoordinate(homeCoord)
            }
        } else if let currentLocation = locationManager.currentLocation {
            // If no home set, start at current location
            currentCoordinate = currentLocation.coordinate
            position = .region(MKCoordinateRegion(
                center: currentLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
            ))
            geocodeCoordinate(currentLocation.coordinate)
        }
    }

    // MARK: - Geocoding

    private func geocodeCoordinate(_ coordinate: CLLocationCoordinate2D) {
        let lat = coordinate.latitude
        let lon = coordinate.longitude

        isGeocoding = true

        Task {
            // Check cache first
            if let cachedName = await sharedGeocodingCache.getCachedName(for: coordinate) {
                debugLog("📍 Using cached location for (\(lat), \(lon)): \(cachedName)")
                await MainActor.run {
                    self.locationName = cachedName
                    self.isGeocoding = false
                }
                return
            }

            // Not in cache, perform geocoding
            debugLog("🌐 Geocoding location (\(lat), \(lon))")
            let location = CLLocation(latitude: lat, longitude: lon)
            let geocoder = CLGeocoder()

            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let placemark = placemarks.first {
                    let name = FormatUtils.formatPlacemarkName(placemark)

                    // Store in cache
                    await sharedGeocodingCache.setCachedName(name, for: coordinate)
                    debugLog("💾 Cached location for (\(lat), \(lon)): \(name)")

                    await MainActor.run {
                        self.locationName = name
                        self.isGeocoding = false
                    }
                } else {
                    await MainActor.run {
                        self.locationName = nil
                        self.isGeocoding = false
                    }
                }
            } catch {
                debugLog("Geocoding error: \(error.localizedDescription)")
                await MainActor.run {
                    self.locationName = nil
                    self.isGeocoding = false
                }
            }
        }
    }
}

struct HomePickerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            HomePickerView()
                .environmentObject(SettingsManager.shared)
                .environmentObject(LocationManager.shared)
        }
    }
}
