import SwiftUI
import Photos
import MapKit
import UserNotifications
import CoreLocation

struct SetupWizardView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var locationManager: LocationManager
    @StateObject private var photoScanner = PhotoLibraryScanner()
    @Environment(\.dismiss) var dismiss

    @State private var currentStep = 0
    @State private var selectedUnitSystem: UnitSystem = .imperial
    @State private var homeCoordinate: CLLocationCoordinate2D?
    @State private var notificationsEnabled = true
    @State private var photoPromptsEnabled = true
    @State private var wantPhotoImport = false
    @State private var showPermissionAlert = false
    @State private var showImportPreview = false

    let totalSteps = 5

    // Check if Next button should be enabled
    private var isNextButtonEnabled: Bool {
        // Step 2 is home location - require it to be set
        if currentStep == 2 {
            return homeCoordinate != nil
        }
        return true
    }

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress indicator (hide when showing import preview)
                if !showImportPreview {
                    HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { step in
                        Capsule()
                            .fill(step <= currentStep ? Color.blue : Color.gray.opacity(0.3))
                            .frame(height: 4)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }

                // Content (hide when showing import preview)
                if !showImportPreview {
                    TabView(selection: $currentStep) {
                    // Step 0: Welcome
                    WelcomeStepView()
                        .tag(0)

                    // Step 1: Units
                    UnitsStepView(selectedUnitSystem: $selectedUnitSystem)
                        .tag(1)

                    // Step 2: Home Location
                    HomeLocationStepView(homeCoordinate: $homeCoordinate)
                        .tag(2)

                    // Step 3: Notifications
                    NotificationsStepView(
                        notificationsEnabled: $notificationsEnabled,
                        photoPromptsEnabled: $photoPromptsEnabled
                    )
                    .tag(3)

                    // Step 4: Photo Import
                    PhotoImportStepView(
                        wantPhotoImport: $wantPhotoImport,
                        photoScanner: photoScanner,
                        showPermissionAlert: $showPermissionAlert
                    )
                    .tag(4)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut, value: currentStep)
                }

                // Navigation buttons (hide when showing import preview)
                if !showImportPreview {
                    HStack(spacing: 20) {
                    if currentStep > 0 {
                        Button(action: {
                            withAnimation {
                                currentStep -= 1
                            }
                        }) {
                            HStack {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                        }
                    }

                    Button(action: {
                        if currentStep < totalSteps - 1 {
                            // If leaving welcome screen, request location permissions
                            if currentStep == 0 {
                                locationManager.requestLocationAuthorization()
                            }

                            // If leaving notifications step, request notification permissions
                            if currentStep == 3 && notificationsEnabled {
                                requestNotificationPermissions()
                            }

                            withAnimation {
                                currentStep += 1
                            }
                        } else {
                            completeSetup()
                        }
                    }) {
                        HStack {
                            Text(currentStep < totalSteps - 1 ? "Next" : "Get Started")
                            if currentStep < totalSteps - 1 {
                                Image(systemName: "chevron.right")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isNextButtonEnabled ? Color.blue : Color.gray.opacity(0.3))
                        .foregroundColor(isNextButtonEnabled ? .white : .gray)
                        .cornerRadius(12)
                    }
                    .disabled(!isNextButtonEnabled)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            }
        }
        .interactiveDismissDisabled()
        .alert("Photo Access Required", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Skip", role: .cancel) {
                wantPhotoImport = false
                dismiss()
            }
        } message: {
            Text("Please grant photo library access in Settings to import records from your photos.")
        }
        .fullScreenCover(isPresented: $showImportPreview, onDismiss: {
            // When import is complete, dismiss wizard
            dismiss()
        }) {
            ImportPreviewView()
                .environmentObject(photoScanner)
                .environmentObject(settings)
        }
    }

    private func completeSetup() {
        // Save settings
        settings.unitSystem = selectedUnitSystem
        // homeCoordinate already saved directly to settings during selection
        settings.notifyOnNewRecord = notificationsEnabled
        settings.photoPromptsEnabled = photoPromptsEnabled
        settings.hasCompletedSetup = true
        settings.saveSettings()

        // Notification permissions already requested when leaving step 3

        // If user wants photo import, trigger it
        if wantPhotoImport {
            checkPhotoPermissionAndImport()
        } else {
            dismiss()
        }
    }

    private func checkPhotoPermissionAndImport() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .authorized, .limited:
            // Show ImportPreviewView immediately so scanning UI appears full-screen
            DispatchQueue.main.async {
                self.showImportPreview = true
                // Start scanning after view appears - ImportPreviewView will display progress
                Task {
                    // Small delay to ensure view transition completes
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    await self.photoScanner.scanPhotoLibrary(homeCoordinate: self.settings.homeCoordinate)
                }
            }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                Task { @MainActor in
                    if newStatus == .authorized || newStatus == .limited {
                        self.showImportPreview = true
                        Task {
                            // Small delay to ensure view transition completes
                            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                            await self.photoScanner.scanPhotoLibrary(homeCoordinate: self.settings.homeCoordinate)
                        }
                    } else {
                        dismiss()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionAlert = true
        @unknown default:
            dismiss()
        }
    }
}

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

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)

            Text(text)
                .font(.body)
        }
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

struct UnitSystemCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(isSelected ? .white : .blue)
                    .frame(width: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(isSelected ? .white : .primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            .padding(20)
            .background(isSelected ? Color.blue : Color(UIColor.secondarySystemBackground))
            .cornerRadius(16)
        }
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

    var body: some View {
        VStack(spacing: 20) {
            // Title
            VStack(spacing: 8) {
                Image(systemName: "house.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)

                Text("Set Your Home")
                    .font(.system(size: 24, weight: .bold))

                Text("Tap the map or search for an address")
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
                    }
                }
            }
            .padding(.horizontal)

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

            // Current location button
            Button(action: {
                if let currentLocation = locationManager.currentLocation {
                    homeCoordinate = currentLocation.coordinate
                    settings.homeCoordinate = currentLocation.coordinate
                    mapPosition = .region(MKCoordinateRegion(
                        center: currentLocation.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
            }) {
                HStack {
                    Image(systemName: "location.fill")
                    Text("Use Current Location")
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .padding(.horizontal)

            // Selected coordinates display
            if let coord = homeCoordinate {
                VStack(spacing: 4) {
                    Text("Home Location Set")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.4f, %.4f", coord.latitude, coord.longitude))
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.top, 4)
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
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                        ))
                    }
                }
            }
        }
    }
}

// MARK: - Notifications Step
struct NotificationsStepView: View {
    @Binding var notificationsEnabled: Bool
    @Binding var photoPromptsEnabled: Bool

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            VStack(spacing: 12) {
                Text("Stay Informed")
                    .font(.system(size: 28, weight: .bold))

                Text("Choose which notifications you'd like to receive")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                NotificationToggleCard(
                    title: "Record Notifications",
                    subtitle: "Get notified when you break a record",
                    icon: "bell.fill",
                    isEnabled: $notificationsEnabled
                )

                NotificationToggleCard(
                    title: "Photo Prompts",
                    subtitle: "Get prompted to attach photos to new records",
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

struct NotificationToggleCard: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(.blue)
                .frame(width: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
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
                Text("Import from Photos")
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

struct ImportOptionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(isSelected ? .white : .blue)
                    .frame(width: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(isSelected ? .white : .primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            .padding(20)
            .background(isSelected ? Color.blue : Color(UIColor.secondarySystemBackground))
            .cornerRadius(16)
        }
    }
}
