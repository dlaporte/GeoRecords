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
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: settings.unitSystem) { _, _ in
                        // Settings automatically switch to the appropriate values via computed properties
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
                            Label("Add Individual Record", systemImage: "plus.circle")
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
                        Label("Clear All Records", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Data Management")
                } footer: {
                    Text("Permanently delete all records from this device and optionally from iCloud.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showClearRecordsSheet) {
                ClearRecordsSheet(
                    deleteFromiCloud: $deleteFromiCloud,
                    onConfirm: {
                        if deleteFromiCloud {
                            // Delete from Core Data (syncs deletion to iCloud)
                            RecordHistoryManager.shared.clearHistory()
                        } else {
                            // Clear local database only - iCloud data preserved
                            RecordHistoryManager.shared.clearLocalOnly()
                        }
                        // Reset setup flag to show wizard
                        settings.hasCompletedSetup = false
                        settings.saveSettings()
                        showClearRecordsSheet = false
                        showSetupWizard = true
                    },
                    onCancel: {
                        showClearRecordsSheet = false
                    }
                )
                .presentationDetents([.height(280)])
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
            }
            .sheet(isPresented: $showManualImport) {
                ManualRecordImportView()
                    .environmentObject(settings)
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
                        if let count = await BackupManager.shared.importBackup(from: url) {
                            importResultMessage = "Successfully imported \(count) records from backup."
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
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "trash.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.red)

            Text("Delete all records?")
                .font(.title2)
                .fontWeight(.semibold)

            Toggle(isOn: $deleteFromiCloud) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete from iCloud")
                        .font(.body)
                    Text(deleteFromiCloud
                         ? "Permanently removes records from all devices"
                         : "Records will sync back from iCloud")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(.red)
            .padding(.horizontal, 24)

            Spacer()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(UIColor.tertiarySystemFill))
                .foregroundColor(.primary)
                .cornerRadius(12)

                Button("Delete") {
                    onConfirm()
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
