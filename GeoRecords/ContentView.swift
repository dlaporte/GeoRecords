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
    @ObservedObject var settings = SettingsManager.shared
    @Binding var isDismissed: Bool
    var selectedTab: Int

    /// Only show location banner on the Records tab after setup is complete
    private var shouldShow: Bool {
        // Don't show if setup hasn't been completed - user hasn't had a chance to grant permission yet
        guard settings.hasCompletedSetup else { return false }
        return !locationManager.healthStatus.isHealthy && !isDismissed && selectedTab == 0
    }

    var body: some View {
        if shouldShow {
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

    // Backup import state
    @State private var showBackupImportConfirm = false
    @State private var backupImportURL: URL?
    @State private var backupInfo: (recordCount: Int, exportDate: Date, deviceName: String)?
    @State private var showBackupImportResult = false
    @State private var backupImportResultMessage = ""

    var body: some View {
        ZStack {
            mainTabContent
            setupOverlays
        }
    }

    // MARK: - View Components

    private var mainTabContent: some View {
        VStack(spacing: 0) {
            LocationHealthBanner(isDismissed: $locationManager.healthBannerDismissed, selectedTab: selectedTab)
            tabView
        }
        .onAppear(perform: handleOnAppear)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            locationManager.updateHealthStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { @MainActor in
                locationManager.scheduleInactivityReminder()
            }
        }
        .onChange(of: deepLinkManager.navigateToStats) { _, shouldNavigate in
            if shouldNavigate {
                selectedTab = 2
                deepLinkManager.navigateToStats = false
            }
        }
        .onChange(of: deepLinkManager.pendingBackupURL) { _, url in
            guard let url = url else { return }
            handleIncomingBackupFile(url)
            deepLinkManager.pendingBackupURL = nil
        }
        .fullScreenCover(isPresented: showingSetupWizardBinding) {
            SetupWizardView().environmentObject(settings)
        }
        .sheet(isPresented: $recordManager.showPhotoPrompt) {
            photoPromptSheet
        }
        .modifier(ContentViewAlertsModifier(
            setupFlowState: $setupFlowState,
            showBackupImportConfirm: $showBackupImportConfirm,
            showBackupImportResult: $showBackupImportResult,
            backupImportResultMessage: backupImportResultMessage,
            backupInfo: backupInfo,
            recordHistoryManager: recordHistoryManager,
            persistenceController: persistenceController,
            restoreFromiCloud: restoreFromiCloud,
            performBackupImport: performBackupImport,
            clearBackupInfo: { backupImportURL = nil; backupInfo = nil }
        ))
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            RecordsView()
                .tabItem { Label("Records", systemImage: "doc.text") }
                .tag(0)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(1)
            StatisticsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
    }

    private var showingSetupWizardBinding: Binding<Bool> {
        Binding(
            get: { setupFlowState == .showingSetupWizard },
            set: { if !$0 { setupFlowState = .none } }
        )
    }

    @ViewBuilder
    private var photoPromptSheet: some View {
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

    @ViewBuilder
    private var setupOverlays: some View {
        if setupFlowState == .checkingCloud {
            checkingCloudOverlay
        }
        if setupFlowState == .restoringFromCloud {
            restoringFromCloudOverlay
        }
    }

    private var checkingCloudOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView().scaleEffect(1.5)
                Text("Checking for iCloud Data").font(.headline)
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.systemBackground)))
            .shadow(radius: 20)
        }
        .transition(.opacity)
    }

    private var restoringFromCloudOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button(action: { setupFlowState = .none }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top)
                ProgressView().scaleEffect(1.5)
                VStack(spacing: 8) {
                    Text("Restoring from iCloud").font(.headline)
                    Text("Your records are syncing from another device")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom)
            }
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.systemBackground)))
            .shadow(radius: 20)
        }
        .transition(.opacity)
    }

    private func handleOnAppear() {
        if !settings.hasCompletedSetup && setupFlowState == .none {
            checkForCloudRestore()
        }
        if PersistenceController.shared.loadError != nil {
            setupFlowState = .databaseError
        }
        locationManager.updateHealthStatus()
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

    // MARK: - Backup Import Handling

    private func handleIncomingBackupFile(_ url: URL) {
        // Need to access security-scoped resource for files from other apps
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Copy file to temp location since original may be removed after share completes
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)  // Remove any existing file

        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            backupImportURL = tempURL

            // Get backup info to display in confirmation
            backupInfo = BackupManager.shared.getBackupInfo(from: tempURL)
            showBackupImportConfirm = true
        } catch {
            debugLog("❌ Failed to copy backup file: \(error.localizedDescription)")
            backupImportResultMessage = "Failed to read backup file."
            showBackupImportResult = true
        }
    }

    private func performBackupImport() {
        guard let url = backupImportURL else { return }

        Task {
            if let count = await BackupManager.shared.importBackup(from: url) {
                await MainActor.run {
                    backupImportResultMessage = "Successfully imported \(count) records from backup."
                    showBackupImportResult = true
                    backupImportURL = nil
                    backupInfo = nil
                }
            } else {
                await MainActor.run {
                    backupImportResultMessage = "Failed to import backup. The file may be corrupted or incompatible."
                    showBackupImportResult = true
                    backupImportURL = nil
                    backupInfo = nil
                }
            }

            // Clean up temp file
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Alerts Modifier

private struct ContentViewAlertsModifier: ViewModifier {
    @Binding var setupFlowState: SetupFlowState
    @Binding var showBackupImportConfirm: Bool
    @Binding var showBackupImportResult: Bool
    let backupImportResultMessage: String
    let backupInfo: (recordCount: Int, exportDate: Date, deviceName: String)?
    let recordHistoryManager: RecordHistoryManager
    let persistenceController: PersistenceController
    let restoreFromiCloud: () -> Void
    let performBackupImport: () -> Void
    let clearBackupInfo: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(isPresented: databaseErrorBinding) {
                Alert(
                    title: Text("Database Error"),
                    message: Text("The app encountered a problem with its database. Your data may have been reset."),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(isPresented: .init(
                get: { recordHistoryManager.showError },
                set: { recordHistoryManager.showError = $0 }
            )) {
                Alert(
                    title: Text("Error"),
                    message: Text(recordHistoryManager.errorMessage ?? "An unknown error occurred"),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(isPresented: .init(
                get: { persistenceController.showDatabaseRecoveryAlert },
                set: { persistenceController.showDatabaseRecoveryAlert = $0 }
            )) {
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
            .alert("Restore from iCloud?", isPresented: restoreChoiceBinding) {
                Button("Restore from iCloud") { restoreFromiCloud() }
                Button("Start Fresh", role: .cancel) { setupFlowState = .showingSetupWizard }
            } message: {
                Text("We found existing records in your iCloud account. Would you like to restore them, or start fresh on this device?")
            }
            .alert("Restore from Backup?", isPresented: $showBackupImportConfirm) {
                Button("Restore") { performBackupImport() }
                Button("Cancel", role: .cancel) { clearBackupInfo() }
            } message: {
                Text(backupImportMessage)
            }
            .alert("Import Complete", isPresented: $showBackupImportResult) {
                Button("OK") {}
            } message: {
                Text(backupImportResultMessage)
            }
    }

    private var databaseErrorBinding: Binding<Bool> {
        Binding(
            get: { setupFlowState == .databaseError },
            set: { if !$0 { setupFlowState = .none } }
        )
    }

    private var restoreChoiceBinding: Binding<Bool> {
        Binding(
            get: { setupFlowState == .showingRestoreChoice },
            set: { if !$0 { setupFlowState = .none } }
        )
    }

    private var backupImportMessage: String {
        if let info = backupInfo {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            let dateString = dateFormatter.string(from: info.exportDate)
            return "This backup contains \(info.recordCount) records from \(info.deviceName), exported on \(dateString).\n\nExisting records will be preserved. Duplicate records will be skipped."
        } else {
            return "Import records from this backup file?"
        }
    }
}
