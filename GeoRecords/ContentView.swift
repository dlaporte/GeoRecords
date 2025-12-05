import SwiftUI
import CoreLocation

struct ContentView: View {
    @EnvironmentObject var deepLinkManager: DeepLinkManager
    @EnvironmentObject var recordManager: RecordManager
    @EnvironmentObject var recordHistoryManager: RecordHistoryManager
    @EnvironmentObject var persistenceController: PersistenceController
    @EnvironmentObject var settings: SettingsManager
    @State private var showDatabaseError = false
    @State private var showSetupWizard = false
    @State private var selectedTab = 0
    @State private var isCheckingForCloudData = false
    @State private var showRestoringMessage = false
    @State private var showRestoreChoiceAlert = false

    var body: some View {
        ZStack {
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
        .onAppear {
            // Check if setup needs to be shown or if we should restore from iCloud
            if !settings.hasCompletedSetup && !isCheckingForCloudData {
                checkForCloudRestore()
            }

            // Check for database errors on app launch
            if PersistenceController.shared.loadError != nil {
                showDatabaseError = true
            }
        }
        .onChange(of: deepLinkManager.navigateToStats) { _, shouldNavigate in
            if shouldNavigate {
                selectedTab = 2  // Navigate to Stats tab
                deepLinkManager.navigateToStats = false  // Reset flag
            }
        }
        .fullScreenCover(isPresented: $showSetupWizard) {
            SetupWizardView()
                .environmentObject(settings)
        }
        .alert(isPresented: $showDatabaseError) {
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
        .alert("Restore from iCloud?", isPresented: $showRestoreChoiceAlert) {
            Button("Restore from iCloud") {
                restoreFromiCloud()
            }
            Button("Start Fresh", role: .cancel) {
                showSetupWizard = true
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
            if isCheckingForCloudData {
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
            if showRestoringMessage {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 20) {
                        HStack {
                            Spacer()
                            Button(action: {
                                showRestoringMessage = false
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
        isCheckingForCloudData = true

        Task {
            // Wait longer for CloudKit to initialize and sync
            // Check multiple times with increasing delays
            var hasCloudData = false
            var attempts = 0
            let maxAttempts = 5

            while attempts < maxAttempts && !hasCloudData {
                attempts += 1
                let delay = UInt64(attempts * 2_000_000_000) // 2, 4, 6, 8, 10 seconds

                debugLog("☁️ Checking for iCloud data (attempt \(attempts)/\(maxAttempts))...")
                try? await Task.sleep(nanoseconds: delay)

                hasCloudData = await persistenceController.hasExistingCloudData()

                if hasCloudData {
                    debugLog("☁️ Found iCloud data after \(attempts * 2) seconds")
                    break
                }

                // If CloudKit is still syncing, wait longer
                if attempts < maxAttempts {
                    debugLog("☁️ No data yet, checking again...")
                }
            }

            await MainActor.run {
                if hasCloudData {
                    // Data exists in iCloud, ask user what to do
                    debugLog("☁️ Existing iCloud data detected, prompting user")
                    showRestoreChoiceAlert = true
                } else {
                    // No cloud data found after all attempts, show setup wizard
                    debugLog("☁️ No iCloud data found after \(attempts) attempts, showing setup wizard")
                    showSetupWizard = true
                }

                isCheckingForCloudData = false
            }
        }
    }

    private func restoreFromiCloud() {
        debugLog("☁️ User chose to restore from iCloud")
        showRestoringMessage = true

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
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(currentLocation) { placemarks, error in
                if let placemark = placemarks?.first {
                    var components: [String] = []
                    if let locality = placemark.locality {
                        components.append(locality)
                    }
                    if let administrativeArea = placemark.administrativeArea {
                        components.append(administrativeArea)
                    }
                    if let country = placemark.country {
                        components.append(country)
                    }
                    let locationName = components.joined(separator: ", ")

                    Task { @MainActor in
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
                showRestoringMessage = false
            }
        }
    }
}
