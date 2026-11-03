import SwiftUI
import MapKit
import CoreLocation
import UserNotifications

/// Individual step views for the setup wizard

// MARK: - Welcome Step
struct WelcomeStepView: View {
    @Environment(\.wizardDensity) private var density
    var body: some View {
        VStack(spacing: density.stackSpacing) {
            Spacer()

            Image("WizardIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: density.heroIconSize, height: density.heroIconSize)

            VStack(spacing: density.titleSpacing) {
                Text("Welcome to GeoRecords")
                    .font(.system(size: density.welcomeTitleSize, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Track your geographical extremes")
                    .font(density.welcomeSubtitle)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: density.listSpacing) {
                FeatureRow(icon: "arrow.up.arrow.down", text: "Track furthest North, South, East, West")
                FeatureRow(icon: "mountain.2.fill", text: "Record highest altitude reached")
                FeatureRow(icon: "house.fill", text: "Measure furthest distance from home")
                FeatureRow(icon: "photo.fill", text: "Attach photos to your records")
            }
            .padding(.top, density.listTopPadding)

            Spacer()
        }
        .padding(.horizontal, density.horizontalPadding)
    }
}

// MARK: - Units Step
struct UnitsStepView: View {
    @Environment(\.wizardDensity) private var density
    @Binding var selectedUnitSystem: UnitSystem

    var body: some View {
        VStack(spacing: density.stackSpacing) {
            Spacer()

            Image(systemName: "ruler")
                .font(.system(size: density.symbolSize))
                .foregroundColor(.blue)

            VStack(spacing: density.titleSpacing) {
                Text("Choose Your Units")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Select your preferred measurement system")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: density.listSpacing) {
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
            .padding(.top, density.listTopPadding)

            Spacer()
        }
        .padding(.horizontal, density.horizontalPadding)
    }
}

// MARK: - Home Location Step
struct HomeLocationStepView: View {
    @Environment(\.wizardDensity) private var density
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
            .padding(.top, density.listTopPadding)

            // Map with tap gesture
            MapReader { reader in
                Map(position: $mapPosition) {
                    if let coord = homeCoordinate {
                        Marker("Home", coordinate: coord)
                            .tint(.red)
                    }
                }
                .frame(height: density.homeMapHeight)
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(FormatUtils.formatCoordinatesWithCardinals(coord))
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
    @Environment(\.wizardDensity) private var density
    @Binding var notificationsEnabled: Bool

    var body: some View {
        VStack(spacing: density.stackSpacing) {
            Spacer()

            Image(systemName: "bell.badge.fill")
                .font(.system(size: density.symbolSize))
                .foregroundColor(.blue)

            VStack(spacing: density.titleSpacing) {
                Text("Record Notifications")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Get notified when you break records")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: density.listSpacing) {
                NotificationToggleCard(
                    title: "Notifications",
                    subtitle: "Receive alerts for yearly and all-time records",
                    icon: "bell.fill",
                    isEnabled: $notificationsEnabled
                )
            }
            .padding(.top, density.listTopPadding)

            Spacer()
        }
        .padding(.horizontal, density.horizontalPadding)
    }
}

// MARK: - Summary Notifications Step
struct SummaryNotificationsStepView: View {
    @Environment(\.wizardDensity) private var density
    @Binding var summaryNotificationsEnabled: Bool

    var body: some View {
        VStack(spacing: density.stackSpacing) {
            Spacer()

            Image(systemName: "calendar.badge.clock")
                .font(.system(size: density.symbolSize))
                .foregroundColor(.orange)

            VStack(spacing: density.titleSpacing) {
                Text("Summary Notifications")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Get monthly and yearly summaries of your achievements")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: density.listSpacing) {
                NotificationToggleCard(
                    title: "Summaries",
                    subtitle: "Receive summaries at the end of each month and year",
                    icon: "calendar.badge.clock",
                    isEnabled: $summaryNotificationsEnabled
                )
            }
            .padding(.top, density.listTopPadding)

            Spacer()
        }
        .padding(.horizontal, density.horizontalPadding)
    }
}

// MARK: - Photo Prompts Step
struct PhotoPromptsStepView: View {
    @Environment(\.wizardDensity) private var density
    @Binding var photoPromptsEnabled: Bool

    var body: some View {
        VStack(spacing: density.stackSpacing) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: density.symbolSize))
                .foregroundColor(.green)

            VStack(spacing: density.titleSpacing) {
                Text("Photo Prompts")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Capture memories when you break records")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: density.listSpacing) {
                NotificationToggleCard(
                    title: "Photo Prompts",
                    subtitle: "Get prompted to attach photos to all-time records",
                    icon: "camera.fill",
                    isEnabled: $photoPromptsEnabled
                )
            }
            .padding(.top, density.listTopPadding)

            Spacer()
        }
        .padding(.horizontal, density.horizontalPadding)
    }
}

// MARK: - Photo Import Step
struct PhotoImportStepView: View {
    @Environment(\.wizardDensity) private var density
    @Binding var wantPhotoImport: Bool
    @ObservedObject var photoScanner: PhotoLibraryScanner
    @Binding var showPermissionAlert: Bool

    var body: some View {
        VStack(spacing: density.stackSpacing) {
            Spacer()

            Image(systemName: "photo.stack.fill")
                .font(.system(size: density.symbolSize))
                .foregroundColor(.blue)

            VStack(spacing: density.titleSpacing) {
                Text("Import Records from Photos")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Scan your photo library to find records from past travels")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: density.listSpacing) {
                ImportOptionCard(
                    title: "Import My Photos",
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
            .padding(.top, density.listTopPadding)

            if photoScanner.isScanning {
                VStack(spacing: density.titleSpacing) {
                    ProgressView(value: photoScanner.progress)
                        .progressViewStyle(.linear)

                    Text("Scanning \(photoScanner.scannedPhotos) of \(photoScanner.totalPhotos) photos...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, density.listTopPadding)
            }

            Spacer()
        }
        .padding(.horizontal, density.horizontalPadding)
    }
}
