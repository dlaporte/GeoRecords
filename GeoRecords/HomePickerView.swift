import SwiftUI
import MapKit
import CoreLocation

struct HomePickerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var locationManager: LocationManager

    @State private var position: MapCameraPosition
    @State private var currentCoordinate: CLLocationCoordinate2D
    @State private var showAlert = false
    @State private var locationName: String?

    init() {
        let defaultCoord = CLLocationCoordinate2D(latitude: 38.897957, longitude: -77.036560)
        // Initialize with default position (will be updated in onAppear)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: defaultCoord,
            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
        )))
        _currentCoordinate = State(initialValue: defaultCoord)
    }

    var body: some View {
        VStack {
            MapReader { reader in
                Map(position: $position) {
                    Marker("", coordinate: currentCoordinate)
                        .tint(.red)
                }
                .frame(height: 300)
                .cornerRadius(10)
                .padding()
                .onTapGesture { position in
                    if let coordinate = reader.convert(position, from: .local) {
                        withAnimation {
                            currentCoordinate = coordinate
                        }
                        geocodeCoordinate(coordinate)
                    }
                }
            }
            .onAppear {
                // Initialize position with home coordinate from environment object
                if let homeCoord = settings.homeCoordinate {
                    currentCoordinate = homeCoord
                    position = .region(MKCoordinateRegion(
                        center: homeCoord,
                        span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
                    ))
                    geocodeCoordinate(homeCoord)
                }
                if let existingName = settings.homeLocationName {
                    locationName = existingName
                }
            }

            VStack(spacing: 4) {
                Text("Selected Location:")
                    .font(.headline)
                if let locationName = locationName {
                    Text(locationName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                }
                Text("Lat: \(currentCoordinate.latitude, specifier: "%.4f"), Lon: \(currentCoordinate.longitude, specifier: "%.4f")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom)

            Button("Use Current Location") {
                if let currentLocation = locationManager.currentLocation {
                    debugLog("Using current location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)")
                    withAnimation {
                        currentCoordinate = currentLocation.coordinate
                        position = .region(MKCoordinateRegion(
                            center: currentLocation.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
                        ))
                    }
                    geocodeCoordinate(currentLocation.coordinate)
                } else {
                    debugLog("No current location available!")
                    showAlert = true
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(8)
            .padding(.horizontal)
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Location Unavailable"), message: Text("We could not determine your current location. Please ensure Location Services are enabled and try again."), dismissButton: .default(Text("OK")))
            }
            
            Button("Set Home Location") {
                settings.homeCoordinate = currentCoordinate
                settings.homeLocationName = locationName
                settings.saveSettings()
                dismiss()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            .padding(.horizontal)

            Spacer()
        }
        .navigationTitle("Select Home Location")
        .onAppear {
            debugLog("HomePickerView appeared. Current position center: \(currentCoordinate.latitude), \(currentCoordinate.longitude)")
            if let current = locationManager.currentLocation {
                debugLog("LocationManager.currentLocation: \(current.coordinate.latitude), \(current.coordinate.longitude)")
            } else {
                debugLog("LocationManager.currentLocation is nil.")
            }
        }
    }

    private func geocodeCoordinate(_ coordinate: CLLocationCoordinate2D) {
        let lat = coordinate.latitude
        let lon = coordinate.longitude

        // Check cache first
        Task {
            if let cachedName = await sharedGeocodingCache.getCachedName(for: coordinate) {
                debugLog("📍 Using cached location for (\(lat), \(lon)): \(cachedName)")
                await MainActor.run {
                    self.locationName = cachedName
                }
                return
            }

            // Not in cache, perform geocoding
            debugLog("🌐 Geocoding location (\(lat), \(lon))")
            let location = CLLocation(latitude: lat, longitude: lon)
            let geocoder = CLGeocoder()

            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let error = error {
                    debugLog("Geocoding error: \(error.localizedDescription)")
                    return
                }

                if let placemark = placemarks?.first {
                    let name = FormatUtils.formatPlacemarkName(placemark)

                    // Store in cache
                    Task {
                        await sharedGeocodingCache.setCachedName(name, for: coordinate)
                        debugLog("💾 Cached location for (\(lat), \(lon)): \(name)")
                    }

                    DispatchQueue.main.async {
                        self.locationName = name
                    }
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
