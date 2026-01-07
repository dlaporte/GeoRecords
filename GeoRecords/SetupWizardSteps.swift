import SwiftUI
import MapKit
import CoreLocation
import UserNotifications

/// Individual step views for the setup wizard

// MARK: - Welcome Step
struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image("WizardIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)

            VStack(spacing: 12) {
                Text("Welcome to GeoRecords")
                    .font(.system(size: 32, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("Track your geographical extremes")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "arrow.up.arrow.down", text: "Track furthest North, South, East, West")
                FeatureRow(icon: "mountain.2.fill", text: "Record highest and lowest altitudes")
                FeatureRow(icon: "house.fill", text: "Measure furthest distance from home")
                FeatureRow(icon: "photo.fill", text: "Attach photos to your records")
            }
            .padding(.top, 20)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Units Step
struct UnitsStepView: View {
    @Binding var selectedUnitSystem: UnitSystem

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "ruler")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            VStack(spacing: 12) {
                Text("Choose Your Units")
                    .font(.system(size: 28, weight: .bold))

                Text("Select your preferred measurement system")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                UnitSystemCard(
                    title: "Imperial",
                    subtitle: "Miles, feet",
                    icon: "flag.fill",
                    isSelected: selectedUnitSystem == .imperial
                ) {
                    selectedUnitSystem = .imperial
                }

                UnitSystemCard(
                    title: "Metric",
                    subtitle: "Kilometers, meters",
                    icon: "globe.europe.africa.fill",
                    isSelected: selectedUnitSystem == .metric
                ) {
                    selectedUnitSystem = .metric
                }
            }
            .padding(.top, 20)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Home Location Step
struct HomeLocationStepView: View {
    @Binding var homeCoordinate: CLLocationCoordinate2D?
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var settings: SettingsManager
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var addressSearch: String = ""
    @State private var isSearching = false
    @State private var homeLocationName: String?

    var body: some View {
        VStack(spacing: 20) {
            // Title
            VStack(spacing: 8) {
                Image(systemName: "house.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)

                Text("Set Your Home")
                    .font(.system(size: 24, weight: .bold))

                Text("Tap the map or search to change location")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            // Map with tap gesture
            MapReader { reader in
                Map(position: $mapPosition) {
                    if let coord = homeCoordinate {
                        Marker("Home", coordinate: coord)
                            .tint(.red)
                    }
                }
                .frame(height: 200)
                .cornerRadius(12)
                .onTapGesture { position in
                    if let coordinate = reader.convert(position, from: .local) {
                        withAnimation {
                            homeCoordinate = coordinate
                            settings.homeCoordinate = coordinate
                        }
                        geocodeCoordinate(coordinate)
                    }
                }
            }
            .padding(.horizontal)
            .onAppear {
                // Automatically zoom to current location when the view appears
                if let currentLocation = locationManager.currentLocation {
                    homeCoordinate = currentLocation.coordinate
                    settings.homeCoordinate = currentLocation.coordinate
                    mapPosition = .region(MKCoordinateRegion(
                        center: currentLocation.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
                    ))
                    geocodeCoordinate(currentLocation.coordinate)
                }
            }
            .onChange(of: locationManager.currentLocation) { _, newLocation in
                // Update when location becomes available (if not already set)
                if homeCoordinate == nil, let newLocation = newLocation {
                    withAnimation {
                        homeCoordinate = newLocation.coordinate
                        settings.homeCoordinate = newLocation.coordinate
                        mapPosition = .region(MKCoordinateRegion(
                            center: newLocation.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
                        ))
                    }
                    geocodeCoordinate(newLocation.coordinate)
                }
            }

            // Address search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search for an address", text: $addressSearch)
                    .textFieldStyle(.plain)
                    .autocapitalization(.none)
                    .onSubmit {
                        searchAddress()
                    }

                if !addressSearch.isEmpty {
                    Button(action: { addressSearch = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal)

            // Selected coordinates display
            if let coord = homeCoordinate {
                VStack(spacing: 4) {
                    Text("Home Location Set")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let locationName = homeLocationName {
                        Text(locationName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                    }
                    Text(FormatUtils.formatCoordinates(coord))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
                .padding(.horizontal)
            }

            Spacer()
        }
    }

    private func searchAddress() {
        isSearching = true
        let geocoder = CLGeocoder()

        geocoder.geocodeAddressString(addressSearch) { placemarks, error in
            Task { @MainActor in
                isSearching = false

                if let placemark = placemarks?.first,
                   let location = placemark.location {
                    withAnimation {
                        homeCoordinate = location.coordinate
                        settings.homeCoordinate = location.coordinate
                        settings.homeAddress = addressSearch
                        mapPosition = .region(MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
                        ))
                    }
                    geocodeCoordinate(location.coordinate)
                }
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
                    self.homeLocationName = cachedName
                    self.settings.homeLocationName = cachedName
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

                    Task { @MainActor in
                        self.homeLocationName = name
                        self.settings.homeLocationName = name
                    }
                }
            }
        }
    }
}

// MARK: - Notifications Step
struct NotificationsStepView: View {
    @Binding var notificationsEnabled: Bool

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            VStack(spacing: 12) {
                Text("Record Notifications")
                    .font(.system(size: 28, weight: .bold))

                Text("Get notified when you break records")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                NotificationToggleCard(
                    title: "Enable Notifications",
                    subtitle: "Receive alerts for yearly and all-time records",
                    icon: "bell.fill",
                    isEnabled: $notificationsEnabled
                )
            }
            .padding(.top, 20)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Summary Notifications Step
struct SummaryNotificationsStepView: View {
    @Binding var summaryNotificationsEnabled: Bool

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            VStack(spacing: 12) {
                Text("Summary Notifications")
                    .font(.system(size: 28, weight: .bold))

                Text("Get monthly and yearly summaries of your achievements")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                NotificationToggleCard(
                    title: "Enable Summaries",
                    subtitle: "Receive summaries at the end of each month and year",
                    icon: "calendar.badge.clock",
                    isEnabled: $summaryNotificationsEnabled
                )
            }
            .padding(.top, 20)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Photo Prompts Step
struct PhotoPromptsStepView: View {
    @Binding var photoPromptsEnabled: Bool

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            VStack(spacing: 12) {
                Text("Photo Prompts")
                    .font(.system(size: 28, weight: .bold))

                Text("Capture memories when you break records")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                NotificationToggleCard(
                    title: "Enable Photo Prompts",
                    subtitle: "Get prompted to attach photos to all-time records",
                    icon: "camera.fill",
                    isEnabled: $photoPromptsEnabled
                )
            }
            .padding(.top, 20)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Photo Import Step
struct PhotoImportStepView: View {
    @Binding var wantPhotoImport: Bool
    @ObservedObject var photoScanner: PhotoLibraryScanner
    @Binding var showPermissionAlert: Bool

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "photo.stack.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            VStack(spacing: 12) {
                Text("Import Records from Photos")
                    .font(.system(size: 28, weight: .bold))

                Text("Scan your photo library to find records from past travels")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                ImportOptionCard(
                    title: "Yes, Import My Photos",
                    subtitle: "Scan photo library for location records",
                    icon: "photo.on.rectangle.angled",
                    isSelected: wantPhotoImport
                ) {
                    wantPhotoImport = true
                }

                ImportOptionCard(
                    title: "Skip for Now",
                    subtitle: "You can import photos later from Settings",
                    icon: "forward.fill",
                    isSelected: !wantPhotoImport
                ) {
                    wantPhotoImport = false
                }
            }
            .padding(.top, 20)

            if photoScanner.isScanning {
                VStack(spacing: 12) {
                    ProgressView(value: photoScanner.progress)
                        .progressViewStyle(.linear)

                    Text("Scanning \(photoScanner.scannedPhotos) of \(photoScanner.totalPhotos) photos...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}
