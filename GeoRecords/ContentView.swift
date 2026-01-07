import SwiftUI
import CoreData
import CoreLocation
import Photos

// MARK: - Setup Flow State

/// Represents mutually exclusive states for the setup/restore flow
enum SetupFlowState: Equatable {
    case none
    case checkingCloud
    case showingRestoreChoice
    case showingNoCloudData  // Shows alert when no iCloud data found
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

    /// Show location banner on all tabs after setup is complete
    private var shouldShow: Bool {
        // Don't show if setup hasn't been completed - user hasn't had a chance to grant permission yet
        guard settings.hasCompletedSetup else { return false }
        return !locationManager.healthStatus.isHealthy && !isDismissed
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

                    // Only show Fix button for app-level issues (not system-level)
                    // System-level issues require navigating to Settings → Privacy manually
                    if !locationManager.healthStatus.isSystemLevel {
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
    @StateObject private var photoScanner = PhotoLibraryScanner()
    @State private var selectedTab = 0
    @State private var setupFlowState: SetupFlowState = .none
    @State private var showPhotoImportWizard = false
    @State private var showNoRecordsView = false

    // Backup import state
    @State private var showBackupImportConfirm = false
    @State private var backupImportURL: URL?
    @State private var backupInfo: (recordCount: Int, regionCount: Int, exportDate: Date, deviceName: String)?
    @State private var showBackupImportResult = false
    @State private var backupImportResultMessage = ""
    @State private var isImportingBackup = false  // Prevents photo wizard from showing during import

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
                selectedTab = 2  // Stats tab
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
        .sheet(isPresented: $showPhotoImportWizard) {
            ImportPreviewView()
                .environmentObject(photoScanner)
                .environmentObject(settings)
                .interactiveDismissDisabled()
                .onAppear {
                    // Start scan if not already scanning
                    if !photoScanner.isScanning && !photoScanner.hasWizardRecords {
                        Task {
                            await photoScanner.scanPhotoLibrary(homeCoordinate: settings.homeCoordinate)
                        }
                    }
                }
        }
        .sheet(isPresented: $showNoRecordsView) {
            NoRecordsView(onScanPhotos: {
                // Small delay to let the NoRecordsView dismiss first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showPhotoImportWizard = true
                }
            })
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
            startFresh: startFresh,
            performBackupImport: performBackupImport,
            clearBackupInfo: { backupImportURL = nil; backupInfo = nil },
            checkForCloudRestore: checkForCloudRestore
        ))
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            RecordsView()
                .tabItem { Label("Records", systemImage: "location.north.fill") }
                .tag(0)
            MapsTabView()
                .tabItem { Label("Regions", systemImage: "map.fill") }
                .tag(1)
            StatisticsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(2)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(4)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToiCloudSync)) { _ in
            selectedTab = 4  // Settings tab
            // Post a delayed notification to scroll to iCloud section after tab switch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .scrollToiCloudSync, object: nil)
            }
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
                ProgressView().scaleEffect(1.5)
                VStack(spacing: 8) {
                    Text("Restoring from iCloud").font(.headline)
                    Text("Your records will sync in the background.\nYou'll be able to use the app shortly.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom)
            }
            .padding(30)
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.systemBackground)))
            .shadow(radius: 20)
        }
        .transition(.opacity)
    }

    private func handleOnAppear() {
        if !settings.hasCompletedSetup && setupFlowState == .none {
            checkForCloudRestore()
        } else if settings.hasCompletedSetup && setupFlowState == .none {
            // Setup was marked complete, but check if there's actually any data
            // This handles the case where user deleted all data but hasCompletedSetup was synced from iCloud
            checkIfDataExistsOrShowWizard()
        }
        if PersistenceController.shared.loadError != nil {
            setupFlowState = .databaseError
        }
        locationManager.updateHealthStatus()
    }

    /// Check if local data exists - if not, check iCloud and show photo import if no data anywhere
    private func checkIfDataExistsOrShowWizard() {
        // Skip this check if we're in the middle of a backup import
        guard !isImportingBackup else {
            debugLog("⏭️ Skipping data check - backup import in progress")
            return
        }

        let context = PersistenceController.shared.container.viewContext

        // Check for RecordHistoryEntry
        let recordRequest: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        recordRequest.fetchLimit = 1
        let recordCount = (try? context.count(for: recordRequest)) ?? 0

        // Check for VisitedRegion
        let regionRequest: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()
        regionRequest.fetchLimit = 1
        let regionCount = (try? context.count(for: regionRequest)) ?? 0

        if recordCount == 0 && regionCount == 0 {
            debugLog("⚠️ hasCompletedSetup is true but no local data found - checking iCloud...")
            // Check iCloud for data - if found, restore; if not, show photo import
            checkForCloudRestoreOrShowPhotoImport()
        } else {
            debugLog("✅ Local data exists: \(recordCount) records, \(regionCount) regions")
        }
    }

    /// Check iCloud for data - restore if found, show no records view if not
    private func checkForCloudRestoreOrShowPhotoImport() {
        setupFlowState = .checkingCloud

        // Block alerts during cloud check to prevent false "new record" prompts
        recordManager.blockAlertsDuringImport(block: true)

        Task {
            debugLog("☁️ Checking iCloud for existing data...")

            do {
                let hasCloudData = try await persistenceController.hasExistingCloudDataThrowing()

                await MainActor.run {
                    setupFlowState = .none
                    if hasCloudData {
                        debugLog("☁️ iCloud records found, auto-restoring")
                        // Note: restoreFromiCloud() will keep alerts blocked and unblock when done
                        restoreFromiCloud()
                    } else {
                        debugLog("☁️ No iCloud records found, showing no records view")
                        recordManager.blockAlertsDuringImport(block: false)
                        showNoRecordsView = true
                    }
                }
            } catch {
                debugLog("☁️ Error checking iCloud data: \(error.localizedDescription)")
                await MainActor.run {
                    setupFlowState = .none
                    recordManager.blockAlertsDuringImport(block: false)
                    // On error, show no records view as fallback
                    showNoRecordsView = true
                }
            }
        }
    }

    private func checkForCloudRestore() {
        setupFlowState = .checkingCloud

        // Block alerts during cloud check to prevent false "new record" prompts
        // while we're waiting for sync and records haven't loaded yet
        recordManager.blockAlertsDuringImport(block: true)

        Task {
            debugLog("☁️ Checking for iCloud data...")

            do {
                // This function waits up to 15 seconds for CloudKit sync to complete
                let hasCloudData = try await persistenceController.hasExistingCloudDataThrowing()

                await MainActor.run {
                    if hasCloudData {
                        debugLog("☁️ iCloud records found, auto-restoring")
                        // Always restore from iCloud automatically - skip the choice dialog
                        // Note: restoreFromiCloud() will keep alerts blocked and unblock when done
                        restoreFromiCloud()
                    } else {
                        debugLog("☁️ No iCloud records found, showing setup wizard")
                        // Unblock alerts - new user starting fresh
                        recordManager.blockAlertsDuringImport(block: false)
                        setupFlowState = .showingSetupWizard
                    }
                }
            } catch {
                debugLog("☁️ Error checking iCloud data: \(error.localizedDescription)")
                await MainActor.run {
                    // Unblock alerts on error
                    recordManager.blockAlertsDuringImport(block: false)
                    setupFlowState = .showingSetupWizard
                }
            }
        }
    }

    private func restoreFromiCloud() {
        debugLog("☁️ User chose to restore from iCloud")
        setupFlowState = .restoringFromCloud

        // Block alerts during restore to prevent false "new record" prompts
        recordManager.blockAlertsDuringImport(block: true)

        // Clear any local data first so iCloud data takes precedence
        debugLog("☁️ Clearing ALL local data to allow fresh iCloud restore...")
        recordManager.resetRecords()

        // Mark setup as complete
        settings.hasCompletedSetup = true
        settings.saveSettings()

        // Request location permission
        LocationManager.shared.requestLocationAuthorization()

        // Request photo library access (needed to display photos from restored records)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            debugLog("📷 Photo library access: \(status == .authorized || status == .limited ? "granted" : "denied")")
        }

        // Destroy the local database completely - this forces a fresh sync from iCloud
        Task {
            let cleared = await RecordHistoryManager.shared.clearLocalOnly()
            debugLog("☁️ Local database cleared: \(cleared)")

            // NOTE: Settings (alerts, reminders, home location) are already synced via iCloud Key-Value Store
            // and were loaded correctly in SettingsManager.init(). Do NOT reset them here, as that would
            // overwrite the user's actual settings that synced from iCloud.

            await MainActor.run {
                // Don't load records yet - wait for iCloud sync
                setupFlowState = .none
                debugLog("☁️ Entering app - waiting for iCloud sync to restore data")
                debugLog("☁️ NOTE: If bogus records persist, they may be synced TO iCloud. Use 'Delete from iCloud' option to fully remove them.")
            }

            // Monitor sync and only load records when sync completes
            await monitorSyncCompletion()

            // Unblock alerts after restore is complete
            await MainActor.run {
                recordManager.blockAlertsDuringImport(block: false)
                debugLog("☁️ iCloud restore complete - alerts unblocked")
            }
        }
    }

    /// User chose to start fresh - clear any synced data and show setup wizard
    private func startFresh() {
        debugLog("🆕 User chose to start fresh - clearing any synced data")

        // Clear all local data including any that synced from iCloud
        recordManager.resetRecords()
        RecordHistoryManager.shared.clearHistory()
        RegionTrackingManager.shared.loadVisitedRegions()  // Reload empty state

        setupFlowState = .showingSetupWizard
    }

    private func monitorSyncCompletion() async {
        // Wait for iCloud sync to actually import data
        var syncWaitTime: TimeInterval = 0
        let maxSyncWait: TimeInterval = 120 // 2 minutes max
        var hasSeenSyncStart = false
        var lastImportTime: Date? = nil

        // Get initial import time
        await MainActor.run {
            lastImportTime = persistenceController.lastImportTime
        }

        while syncWaitTime < maxSyncWait {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // Check every 2 seconds
            syncWaitTime += 2

            let (isSyncing, currentImportTime) = await MainActor.run {
                (persistenceController.isSyncing, persistenceController.lastImportTime)
            }

            // Track if sync has started
            if isSyncing {
                hasSeenSyncStart = true
            }

            // Check if a new import has completed
            if let currentTime = currentImportTime,
               (lastImportTime.map { currentTime > $0 } ?? true) {
                // New import completed - reload records
                await MainActor.run {
                    debugLog("☁️ iCloud import completed at \(currentTime) - reloading records")
                    recordManager.loadRecordsFromHistory()
                }
                return
            }

            // If sync finished without seeing an import, still try loading
            if hasSeenSyncStart && !isSyncing {
                await MainActor.run {
                    debugLog("☁️ iCloud sync completed (no new import) - reloading records")
                    recordManager.loadRecordsFromHistory()
                }
                return
            }

            // Periodically reload to show progress
            if Int(syncWaitTime) % 10 == 0 {
                await MainActor.run {
                    recordManager.loadRecordsFromHistory()
                    // Count all-time records as a proxy for total loaded
                    let count = RecordType.allCases.compactMap {
                        recordManager.getRecord(type: $0.rawValue, timeFrame: .allTime)
                    }.count
                    debugLog("☁️ Waiting for sync (\(Int(syncWaitTime))s) - currently have \(count) all-time records")
                }
            }
        }

        // Max wait reached
        await MainActor.run {
            debugLog("☁️ Sync timeout after \(Int(maxSyncWait))s - loading available records")
            recordManager.loadRecordsFromHistory()
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

        isImportingBackup = true

        Task {
            if let result = await BackupManager.shared.importBackup(from: url) {
                await MainActor.run {
                    isImportingBackup = false
                    var parts: [String] = []
                    if result.records > 0 {
                        parts.append("\(result.records) record\(result.records == 1 ? "" : "s")")
                    }
                    if result.regions > 0 {
                        parts.append("\(result.regions) visited region\(result.regions == 1 ? "" : "s")")
                    }
                    let summary = parts.isEmpty ? "backup data" : parts.joined(separator: " and ")
                    backupImportResultMessage = "Successfully imported \(summary) from backup."
                    showBackupImportResult = true
                    backupImportURL = nil
                    backupInfo = nil
                }
            } else {
                await MainActor.run {
                    isImportingBackup = false
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
    let backupInfo: (recordCount: Int, regionCount: Int, exportDate: Date, deviceName: String)?
    let recordHistoryManager: RecordHistoryManager
    let persistenceController: PersistenceController
    let restoreFromiCloud: () -> Void
    let startFresh: () -> Void
    let performBackupImport: () -> Void
    let clearBackupInfo: () -> Void
    let checkForCloudRestore: () -> Void

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
                Button("Start Fresh", role: .cancel) { startFresh() }
            } message: {
                Text("We found existing records in your iCloud account. Would you like to restore them, or start fresh on this device?")
            }
            .alert("No iCloud Data Found", isPresented: noCloudDataBinding) {
                Button("Keep Waiting") { checkForCloudRestore() }  // Uses closure from modifier
                Button("Start Fresh", role: .cancel) { startFresh() }
            } message: {
                Text("No records found after waiting 60 seconds. iCloud sync may take longer for large datasets.\n\nChoose 'Keep Waiting' to check again, or 'Start Fresh' to set up as a new device.")
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

    private var noCloudDataBinding: Binding<Bool> {
        Binding(
            get: { setupFlowState == .showingNoCloudData },
            set: { if !$0 { setupFlowState = .none } }
        )
    }

    private var backupImportMessage: String {
        if let info = backupInfo {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            let dateString = dateFormatter.string(from: info.exportDate)

            var contents: [String] = []
            if info.recordCount > 0 {
                contents.append("\(info.recordCount) record\(info.recordCount == 1 ? "" : "s")")
            }
            if info.regionCount > 0 {
                contents.append("\(info.regionCount) visited region\(info.regionCount == 1 ? "" : "s")")
            }

            let contentsString = contents.isEmpty ? "no data" : contents.joined(separator: " and ")
            return "This backup contains \(contentsString) from \(info.deviceName), exported on \(dateString).\n\nThis will replace all existing records and settings."
        } else {
            return "Restore from this backup file? This will replace all existing data."
        }
    }
}
