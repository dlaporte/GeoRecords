import SwiftUI
import UniformTypeIdentifiers

// Custom UTType for GeoRecords backup files
extension UTType {
    static var georecordsBackup: UTType {
        UTType(exportedAs: "com.georecords.backup")
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @StateObject private var photoScanner = PhotoLibraryScanner()
    @ObservedObject private var persistenceController = PersistenceController.shared

    // State for confirmation alerts
    @State private var showClearRecordsSheet = false
    @State private var deleteFromiCloud = false
    @State private var showImportView = false
    @State private var showNoRecordsView = false
    @State private var showPermissionAlert = false
    @State private var showManualImport = false
    @State private var showSetupWizard = false
    @State private var showBackupShareSheet = false
    @State private var backupURL: URL?
    @State private var showBackupError = false
    @State private var showImportFilePicker = false
    @State private var showImportResult = false
    @State private var importResultMessage = ""
    @State private var isExporting = false

    // Available options for Latitude/Longitude deltas.
    let deltaOptions: [Double] = [0.1, 0.2, 0.5, 1.0, 2.0, 5.0]

    // Imperial altitude options (in feet, stored as meters internally)
    let imperialAltitudeOptions: [(feet: Int, meters: Double)] = [
        (50, 15.24),
        (100, 30.48),
        (500, 152.4),
        (1000, 304.8),
        (5000, 1524.0),
        (10000, 3048.0)
    ]

    // Metric altitude options (in meters)
    let metricAltitudeOptions: [Double] = [10, 50, 100, 500, 1000]

    // Imperial distance options (stored as meters internally)
    let imperialDistanceOptions: [(label: String, meters: Double)] = [
        ("0.1 mi", 160.9344),
        ("0.5 mi", 804.672),
        ("1 mi", 1609.344),
        ("5 mi", 8046.72),
        ("10 mi", 16093.44)
    ]

    // Metric distance options (in meters)
    let metricDistanceOptions: [(label: String, meters: Double)] = [
        ("100 m", 100.0),
        ("500 m", 500.0),
        ("1 km", 1000.0),
        ("5 km", 5000.0),
        ("10 km", 10000.0)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                // MARK: - Home Location Section
                Section(header: Text("Home Location")) {
                    NavigationLink(destination: HomePickerView()) {
                        HStack {
                            Text("Home")
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let locationName = settings.homeLocationName {
                                    Text(locationName)
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.trailing)
                                }
                                if let coord = settings.homeCoordinate {
                                    Text("(\(coord.latitude, specifier: "%.4f"), \(coord.longitude, specifier: "%.4f"))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Not set")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                // MARK: - Units Section
                Section(header: Text("Units")) {
                    Picker("Units", selection: $settings.unitSystem) {
                        Text("Imperial").tag(UnitSystem.imperial)
                        Text("Metric").tag(UnitSystem.metric)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.unitSystem) { _, _ in
                        settings.saveSettings()
                    }
                }

                // MARK: - Minimum Deltas Section
                Section {
                    Picker("Latitude Δ (deg)", selection: $settings.minLatitudeDelta) {
                        ForEach(deltaOptions, id: \.self) { value in
                            Text(String(format: "%.1f", value))
                                .tag(value)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .onChange(of: settings.minLatitudeDelta) { _, _ in
                        settings.saveSettings()
                    }

                    Picker("Longitude Δ (deg)", selection: $settings.minLongitudeDelta) {
                        ForEach(deltaOptions, id: \.self) { value in
                            Text(String(format: "%.1f", value))
                                .tag(value)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .onChange(of: settings.minLongitudeDelta) { _, _ in
                        settings.saveSettings()
                    }

                    // Altitude picker - show imperial OR metric options
                    if settings.unitSystem == .imperial {
                        Picker("Altitude Δ", selection: $settings.minAltitudeDeltaMeters) {
                            ForEach(imperialAltitudeOptions, id: \.meters) { option in
                                Text("\(option.feet) ft")
                                    .tag(option.meters)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: settings.minAltitudeDeltaMeters) { _, _ in
                            settings.saveSettings()
                        }
                    } else {
                        Picker("Altitude Δ", selection: $settings.minAltitudeDeltaMeters) {
                            ForEach(metricAltitudeOptions, id: \.self) { meters in
                                Text("\(Int(meters)) m")
                                    .tag(meters)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: settings.minAltitudeDeltaMeters) { _, _ in
                            settings.saveSettings()
                        }
                    }

                    // Distance picker - show imperial OR metric options
                    if settings.unitSystem == .imperial {
                        Picker("Distance Δ", selection: $settings.minDistanceDeltaMeters) {
                            ForEach(imperialDistanceOptions, id: \.meters) { option in
                                Text(option.label)
                                    .tag(option.meters)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: settings.minDistanceDeltaMeters) { _, _ in
                            settings.saveSettings()
                        }
                    } else {
                        Picker("Distance Δ", selection: $settings.minDistanceDeltaMeters) {
                            ForEach(metricDistanceOptions, id: \.meters) { option in
                                Text(option.label)
                                    .tag(option.meters)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: settings.minDistanceDeltaMeters) { _, _ in
                            settings.saveSettings()
                        }
                    }

                    Button("Reset to Defaults") {
                        settings.resetDeltasToDefaults()
                    }
                } header: {
                    Text("Minimum Deltas")
                } footer: {
                    Text("New records must exceed current records by at least these amounts. Higher values reduce noise from minor location changes.")
                }

                // MARK: - Record Alerts Section
                Section {
                    Toggle("Monthly Records", isOn: $settings.notifyOnMonthlyRecords)
                        .onChange(of: settings.notifyOnMonthlyRecords) { _, _ in
                            settings.saveSettings()
                        }

                    Toggle("Yearly Records", isOn: $settings.notifyOnYearlyRecords)
                        .onChange(of: settings.notifyOnYearlyRecords) { _, _ in
                            settings.saveSettings()
                        }

                    Toggle("All-Time Records", isOn: $settings.notifyOnAllTimeRecords)
                        .onChange(of: settings.notifyOnAllTimeRecords) { _, _ in
                            settings.saveSettings()
                        }
                } header: {
                    Text("Record Alerts")
                } footer: {
                    Text("Get notified when you set a new geographical record.")
                }

                // MARK: - Reminders Section
                Section {
                    Toggle("Summary Notifications", isOn: $settings.summaryNotificationsEnabled)
                        .onChange(of: settings.summaryNotificationsEnabled) { _, _ in
                            settings.saveSettings()
                            SummaryNotificationManager.shared.scheduleSummaryNotifications()
                        }

                    Toggle("Photo Prompts", isOn: $settings.photoPromptsEnabled)
                        .onChange(of: settings.photoPromptsEnabled) { _, _ in
                            settings.saveSettings()
                        }

                    Toggle("Inactivity Reminder", isOn: $settings.inactivityReminderEnabled)
                        .onChange(of: settings.inactivityReminderEnabled) { _, _ in
                            settings.saveSettings()
                            // Reschedule or cancel the reminder
                            Task { @MainActor in
                                if settings.inactivityReminderEnabled {
                                    LocationManager.shared.scheduleInactivityReminder()
                                } else {
                                    LocationManager.shared.cancelInactivityReminder()
                                }
                            }
                        }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("Photo prompts appear when you set an all-time record. Summaries notify you of your records at month/year end. Inactivity reminder fires after 3 days without tracking.")
                }

                // MARK: - iCloud Sync Section
                Section(header: Text("iCloud Sync")) {
                    EmptyView().id("iCloudSync")  // Anchor for scrolling
                    HStack {
                        Image(systemName: "icloud")
                            .foregroundColor(.blue)
                        Text("Status")
                        Spacer()
                        if persistenceController.isSyncing {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Syncing...")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        } else if persistenceController.lastSyncError != nil {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Error")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Up to date")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }

                    if let error = persistenceController.lastSyncError {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Text("Your records automatically sync across all devices signed into the same iCloud account.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // MARK: - Import Records Section
                Section {
                    Button(action: {
                        requestPhotoAccess()
                    }) {
                        HStack {
                            Label("Import Photos", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(action: {
                        showImportFilePicker = true
                    }) {
                        HStack {
                            Label("Import Backup", systemImage: "square.and.arrow.down")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(action: {
                        showManualImport = true
                    }) {
                        HStack {
                            Label("Add Location", systemImage: "plus.circle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Import Records")
                } footer: {
                    Text("Import records from your photo library, a backup file, or add them manually.")
                }

                // MARK: - Export Section
                Section {
                    Button(action: {
                        Task {
                            isExporting = true
                            if let url = await BackupManager.shared.exportBackup() {
                                backupURL = url
                                showBackupShareSheet = true
                            } else {
                                showBackupError = true
                            }
                            isExporting = false
                        }
                    }) {
                        HStack {
                            Label("Export Backup", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isExporting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .disabled(isExporting)
                } header: {
                    Text("Export Records")
                } footer: {
                    Text("Save your records to a backup file. Photos are stored as references to your Photos library.")
                }

                // MARK: - Data Management Section
                Section {
                    Button(role: .destructive) {
                        deleteFromiCloud = false  // Reset to default
                        showClearRecordsSheet = true
                    } label: {
                        Label("Delete All Records", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Data Management")
                } footer: {
                    Text("Permanently delete all records from this device and optionally from iCloud.")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToiCloudSync)) { _ in
                withAnimation {
                    proxy.scrollTo("iCloudSync", anchor: .top)
                }
            }
            } // ScrollViewReader
            .navigationTitle("Settings")
            .sheet(isPresented: $showClearRecordsSheet) {
                ClearRecordsSheet(
                    deleteFromiCloud: $deleteFromiCloud,
                    persistenceController: persistenceController,
                    onComplete: {
                        showClearRecordsSheet = false
                        // Small delay to let sheet dismiss, then show no records view
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showNoRecordsView = true
                        }
                    },
                    onCancel: {
                        showClearRecordsSheet = false
                    },
                    onFullReset: {
                        showClearRecordsSheet = false
                        // Small delay to let sheet dismiss, then show setup wizard
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showSetupWizard = true
                        }
                    }
                )
                .environmentObject(settings)
                .presentationDetents([.height(440)])
            }
            .fullScreenCover(isPresented: $showSetupWizard) {
                SetupWizardView()
                    .environmentObject(settings)
            }
            .alert("Photo Access Required", isPresented: $showPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Please grant photo library access in Settings to import records from your photos.")
            }
            .sheet(isPresented: $showImportView) {
                ImportPreviewView()
                    .environmentObject(photoScanner)
                    .environmentObject(settings)
                    .interactiveDismissDisabled()  // Prevent accidental swipe-down dismissal
                    .onAppear {
                        // Start scan if not already scanning (may have been triggered by requestPhotoAccess)
                        if !photoScanner.isScanning && !photoScanner.hasWizardRecords {
                            Task {
                                await photoScanner.scanPhotoLibrary(homeCoordinate: settings.homeCoordinate)
                            }
                        }
                    }
            }
            .sheet(isPresented: $showManualImport) {
                ManualRecordImportView()
                    .environmentObject(settings)
            }
            .sheet(isPresented: $showNoRecordsView) {
                NoRecordsView(onScanPhotos: {
                    // Small delay to let the NoRecordsView dismiss first
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showImportView = true
                    }
                })
            }
            .sheet(isPresented: $showBackupShareSheet) {
                if let url = backupURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .fileImporter(
                isPresented: $showImportFilePicker,
                allowedContentTypes: [.georecordsBackup, .json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }

                    // Need to access security-scoped resource
                    guard url.startAccessingSecurityScopedResource() else {
                        importResultMessage = "Could not access the selected file."
                        showImportResult = true
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }

                    Task {
                        if let result = await BackupManager.shared.importBackup(from: url) {
                            var parts: [String] = []
                            if result.records > 0 {
                                parts.append("\(result.records) record\(result.records == 1 ? "" : "s")")
                            }
                            if result.regions > 0 {
                                parts.append("\(result.regions) visited region\(result.regions == 1 ? "" : "s")")
                            }
                            let summary = parts.isEmpty ? "backup data" : parts.joined(separator: " and ")
                            importResultMessage = "Successfully imported \(summary) from backup."
                        } else {
                            importResultMessage = "Failed to import backup. The file may be corrupted or incompatible."
                        }
                        showImportResult = true
                    }
                case .failure(let error):
                    importResultMessage = "Error selecting file: \(error.localizedDescription)"
                    showImportResult = true
                }
            }
            .alert("Backup Error", isPresented: $showBackupError) {
                Button("OK") {}
            } message: {
                Text("Failed to create backup. Please try again.")
            }
            .alert("Import Complete", isPresented: $showImportResult) {
                Button("OK") {}
            } message: {
                Text(importResultMessage)
            }
        }
    }

    private func requestPhotoAccess() {
        photoScanner.requestPhotoLibraryAccess { granted in
            if granted {
                showImportView = true
                Task {
                    await photoScanner.scanPhotoLibrary(homeCoordinate: settings.homeCoordinate)
                }
            } else {
                showPermissionAlert = true
            }
        }
    }
}

// MARK: - Clear Records Sheet

struct ClearRecordsSheet: View {
    @Binding var deleteFromiCloud: Bool
    @EnvironmentObject var settings: SettingsManager
    @ObservedObject var persistenceController: PersistenceController
    let onComplete: () -> Void
    let onCancel: () -> Void
    let onFullReset: () -> Void  // Called when full app reset is performed

    @State private var isDeleting = false
    @State private var statusMessage = ""
    @State private var deleteZone = false  // Complete iCloud reset
    @State private var fullAppReset = false  // Factory reset

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if isDeleting {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.bottom, 8)

                Text(fullAppReset ? "Resetting app..." : "Deleting records...")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Image(systemName: fullAppReset ? "arrow.counterclockwise.circle.fill" : "trash.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.red)

                Text(fullAppReset ? "Reset app completely?" : "Delete all records?")
                    .font(.title2)
                    .fontWeight(.semibold)

                VStack(spacing: 16) {
                    Toggle(isOn: $deleteFromiCloud) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Also delete from iCloud")
                                .font(.body)
                            Text(deleteFromiCloud
                                 ? "Permanently removes records from all devices"
                                 : "Records will sync back from iCloud")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(.red)
                    .disabled(deleteZone)

                    if deleteFromiCloud {
                        Toggle(isOn: $deleteZone) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Complete iCloud reset")
                                    .font(.body)
                                Text("Deletes the iCloud sync zone entirely")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tint(.red)
                        .disabled(fullAppReset)
                    }

                    if deleteZone {
                        Toggle(isOn: $fullAppReset) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Complete app reset")
                                    .font(.body)
                                Text("Resets everything as if freshly installed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tint(.red)
                    }
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            if !isDeleting {
                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(UIColor.tertiarySystemFill))
                    .foregroundColor(.primary)
                    .cornerRadius(12)

                    Button(fullAppReset ? "Reset" : "Delete") {
                        performDelete()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .onChange(of: deleteZone) { _, newValue in
            // If turning off deleteZone, also turn off fullAppReset
            if !newValue {
                fullAppReset = false
            }
        }
        .onChange(of: deleteFromiCloud) { _, newValue in
            // If turning off deleteFromiCloud, also turn off deleteZone and fullAppReset
            if !newValue {
                deleteZone = false
                fullAppReset = false
            }
        }
    }

    private func performDelete() {
        if deleteFromiCloud {
            // Delete from iCloud - need to wait for sync
            isDeleting = true
            statusMessage = "Deleting local records..."

            // Perform the local deletion first
            RecordHistoryManager.shared.clearHistory()

            Task {
                if deleteZone {
                    // Complete reset - delete the CloudKit zone entirely
                    await MainActor.run {
                        statusMessage = "Deleting iCloud zone..."
                    }

                    let zoneDeleted = await persistenceController.deleteCloudKitZone()

                    await MainActor.run {
                        if zoneDeleted {
                            statusMessage = "iCloud zone deleted"
                        } else {
                            statusMessage = "Zone deletion failed, but local data cleared"
                        }
                    }

                    // If full app reset, also reset settings
                    if fullAppReset {
                        await MainActor.run {
                            statusMessage = "Resetting settings..."
                        }

                        await MainActor.run {
                            // Reset all settings to defaults
                            settings.resetToDefaults()

                            // Clear iCloud Key-Value store
                            let store = NSUbiquitousKeyValueStore.default
                            for key in store.dictionaryRepresentation.keys {
                                store.removeObject(forKey: key)
                            }
                            store.synchronize()

                            statusMessage = "App reset complete"
                        }

                        try? await Task.sleep(nanoseconds: 500_000_000) // Brief pause
                        await MainActor.run {
                            onFullReset()
                        }
                    } else {
                        try? await Task.sleep(nanoseconds: 500_000_000) // Brief pause
                        await MainActor.run {
                            onComplete()
                        }
                    }
                } else {
                    // Normal iCloud delete - wait for sync
                    let exportTimeBefore = persistenceController.lastExportTime

                    await MainActor.run {
                        statusMessage = "Syncing deletions to iCloud..."
                    }

                    // Wait up to 30 seconds for export to complete
                    let timeout = Date().addingTimeInterval(30)

                    while Date() < timeout {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

                        // Check if a new export completed
                        if let newExportTime = persistenceController.lastExportTime,
                           exportTimeBefore == nil || newExportTime > exportTimeBefore! {
                            await MainActor.run {
                                statusMessage = "Deletion synced to iCloud"
                            }
                            try? await Task.sleep(nanoseconds: 500_000_000) // Brief pause
                            await MainActor.run {
                                onComplete()
                            }
                            return
                        }

                        // Update status if still syncing
                        if persistenceController.pendingExport {
                            await MainActor.run {
                                statusMessage = "Syncing deletions to iCloud..."
                            }
                        }
                    }

                    // Timeout - complete anyway
                    await MainActor.run {
                        onComplete()
                    }
                }
            }
        } else {
            // Local only - no need to wait
            RecordHistoryManager.shared.clearLocalOnly()
            onComplete()
        }
    }
}

// MARK: - Share Sheet

import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
