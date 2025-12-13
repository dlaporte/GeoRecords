import SwiftUI
import CoreLocation

// MARK: - Setup Flow State

/// Represents mutually exclusive states for the setup/restore flow
enum SetupFlowState: Equatable {
    case none
    case checkingCloud
    case showingRestoreChoice
    case restoringFromCloud
    case showingSetupWizard
    case databaseError
}

// MARK: - Location Health Banner

struct LocationHealthBanner: View {
    @ObservedObject var locationManager = LocationManager.shared
    @Binding var isDismissed: Bool

    var body: some View {
        if !locationManager.healthStatus.isHealthy && !isDismissed {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: locationManager.healthStatus.icon)
                        .font(.title3)
                        .foregroundColor(locationManager.healthStatus.color)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(locationManager.healthStatus.isDisabled ? "Location Disabled" : "Location Issue")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text(locationManager.healthStatus.message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button(action: {
                        locationManager.openSettings()
                    }) {
                        Text("Fix")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(locationManager.healthStatus.color)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }

                    Button(action: {
                        withAnimation {
                            isDismissed = true
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(UIColor.secondarySystemBackground))
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var deepLinkManager: DeepLinkManager
    @EnvironmentObject var recordManager: RecordManager
    @EnvironmentObject var recordHistoryManager: RecordHistoryManager
    @EnvironmentObject var persistenceController: PersistenceController
    @EnvironmentObject var settings: SettingsManager
    @ObservedObject var locationManager = LocationManager.shared
    @State private var selectedTab = 0
    @State private var setupFlowState: SetupFlowState = .none

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Location health banner at top
                LocationHealthBanner(isDismissed: $locationManager.healthBannerDismissed)

            TabView(selection: $selectedTab) {
                RecordsView()
                    .tabItem {
                        Label("Records", systemImage: "doc.text")
                    }
                    .tag(0)
                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock")
                    }
                    .tag(1)
                StatisticsView()
                    .tabItem {
                        Label("Stats", systemImage: "chart.bar.fill")
                    }
                    .tag(2)
                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(3)
            }
        }  // End VStack
        .onAppear {
            // Check if setup needs to be shown or if we should restore from iCloud
            if !settings.hasCompletedSetup && setupFlowState == .none {
                checkForCloudRestore()
            }

            // Check for database errors on app launch
            if PersistenceController.shared.loadError != nil {
                setupFlowState = .databaseError
            }

            // Check location health status
            locationManager.updateHealthStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Re-check health when returning from Settings
            locationManager.updateHealthStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Reschedule inactivity reminder each time app becomes active
            // This "dead man's switch" approach ensures the notification only fires
            // if the app hasn't been opened in X days
            Task { @MainActor in
                locationManager.scheduleInactivityReminder()
            }
        }
        .onChange(of: deepLinkManager.navigateToStats) { _, shouldNavigate in
            if shouldNavigate {
                selectedTab = 2  // Navigate to Stats tab
                deepLinkManager.navigateToStats = false  // Reset flag
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { setupFlowState == .showingSetupWizard },
            set: { if !$0 { setupFlowState = .none } }
        )) {
            SetupWizardView()
                .environmentObject(settings)
        }
        .alert(isPresented: Binding(
            get: { setupFlowState == .databaseError },
            set: { if !$0 { setupFlowState = .none } }
        )) {
            Alert(
                title: Text("Database Error"),
                message: Text("The app encountered a problem with its database. Your data may have been reset."),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $recordHistoryManager.showError) {
            Alert(
                title: Text("Error"),
                message: Text(recordHistoryManager.errorMessage ?? "An unknown error occurred"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $persistenceController.showDatabaseRecoveryAlert) {
            Alert(
                title: Text("Database Corrupted"),
                message: Text("The app's database is corrupted and cannot be loaded. Would you like to reset it? This will delete all your records permanently."),
                primaryButton: .destructive(Text("Reset Database")) {
                    if let storeURL = persistenceController.container.persistentStoreDescriptions.first?.url {
                        persistenceController.attemptDatabaseRecovery(storeURL: storeURL)
                    }
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
        .alert("Restore from iCloud?", isPresented: Binding(
            get: { setupFlowState == .showingRestoreChoice },
            set: { if !$0 { setupFlowState = .none } }
        )) {
            Button("Restore from iCloud") {
                restoreFromiCloud()
            }
            Button("Start Fresh", role: .cancel) {
                setupFlowState = .showingSetupWizard
            }
        } message: {
            Text("We found existing records in your iCloud account. Would you like to restore them, or start fresh on this device?")
        }
        .sheet(isPresented: $recordManager.showPhotoPrompt) {
            if let pending = recordManager.pendingRecordForPhoto {
                PhotoPicker(
                    recordType: pending.type,
                    onPhotoSelected: { photoData in
                        recordManager.attachPhotoToRecord(recordType: pending.type, photoData: photoData)
                    },
                    onDismiss: {
                        recordManager.showPhotoPrompt = false
                        recordManager.pendingRecordForPhoto = nil
                    }
                )
            }
        }

            // Checking for iCloud data overlay
            if setupFlowState == .checkingCloud {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Checking for iCloud Data")
                            .font(.headline)
                    }
                    .padding(40)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(UIColor.systemBackground))
                    )
                    .shadow(radius: 20)
                }
                .transition(.opacity)
            }

            // Restoring from iCloud overlay
            if setupFlowState == .restoringFromCloud {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 20) {
                        HStack {
                            Spacer()
                            Button(action: {
                                setupFlowState = .none
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top)

                        ProgressView()
                            .scaleEffect(1.5)

                        VStack(spacing: 8) {
                            Text("Restoring from iCloud")
                                .font(.headline)

                            Text("Your records are syncing from another device")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.bottom)
                    }
                    .frame(width: 300)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(UIColor.systemBackground))
                    )
                    .shadow(radius: 20)
                }
                .transition(.opacity)
            }
        }
    }

    private func checkForCloudRestore() {
        setupFlowState = .checkingCloud

        Task {
            debugLog("☁️ Checking for iCloud data...")

            do {
                // This function waits up to 15 seconds for CloudKit sync to complete
                let hasCloudData = try await persistenceController.hasExistingCloudDataThrowing()

                await MainActor.run {
                    if hasCloudData {
                        debugLog("☁️ Existing iCloud data detected, prompting user")
                        setupFlowState = .showingRestoreChoice
                    } else {
                        debugLog("☁️ No iCloud data found, showing setup wizard")
                        setupFlowState = .showingSetupWizard
                    }
                }
            } catch {
                debugLog("☁️ Error checking iCloud data: \(error.localizedDescription)")
                await MainActor.run {
                    setupFlowState = .showingSetupWizard
                }
            }
        }
    }

    private func restoreFromiCloud() {
        debugLog("☁️ User chose to restore from iCloud")
        setupFlowState = .restoringFromCloud

        // Set reasonable defaults for settings (user can customize later)
        // Keep notifications disabled by default to respect privacy
        settings.notifyOnMonthlyRecords = false
        settings.notifyOnYearlyRecords = false
        settings.notifyOnAllTimeRecords = false
        settings.summaryNotificationsEnabled = false
        settings.photoPromptsEnabled = false

        // Use device's current location as home if available
        if let currentLocation = LocationManager.shared.currentLocation {
            settings.homeCoordinate = currentLocation.coordinate

            // Also geocode to get location name
            Task {
                if let locationName = await reverseGeocode(location: currentLocation) {
                    await MainActor.run {
                        self.settings.homeLocationName = locationName
                        self.settings.saveSettings()
                        debugLog("☁️ Set home to: \(locationName)")
                    }
                } else {
                    debugLog("☁️ Set home to current location (geocoding failed)")
                }
            }
        }

        // Mark setup as complete
        settings.hasCompletedSetup = true
        settings.saveSettings()

        // Reload records from synced data
        recordManager.loadRecordsFromHistory()

        // Request location permission
        LocationManager.shared.requestLocationAuthorization()

        // Hide message after a delay
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await MainActor.run {
                setupFlowState = .none
            }
        }
    }
}
