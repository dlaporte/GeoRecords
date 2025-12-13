import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @StateObject private var photoScanner = PhotoLibraryScanner()
    @ObservedObject private var persistenceController = PersistenceController.shared

    // State for confirmation alerts
    @State private var showConsolidateAlert = false
    @State private var showClearRecordsAlert = false
    @State private var showConsolidateResult = false
    @State private var consolidateResultMessage = ""
    @State private var showImportView = false
    @State private var showPermissionAlert = false
    @State private var showManualImport = false
    @State private var showSetupWizard = false
    
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
                // MARK: - Notifications Section
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

                    if settings.inactivityReminderEnabled {
                        Picker("Remind after", selection: $settings.inactivityReminderDays) {
                            Text("3 days").tag(3)
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: settings.inactivityReminderDays) { _, _ in
                            settings.saveSettings()
                            // Reschedule with new interval
                            Task { @MainActor in
                                LocationManager.shared.scheduleInactivityReminder()
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Inactivity reminder sends a notification if the app hasn't tracked any locations in the selected time period.")
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

                    Text("Your records automatically sync across all devices signed into the same iCloud account")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                Section(header: Text("Minimum Deltas")) {
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
                }
                
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
                
                // MARK: - Import Section
                Section(header: Text("Import")) {
                    Button(action: {
                        requestPhotoAccess()
                    }) {
                        HStack {
                            Label("Import from Photos", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("Scan your photo library to discover records from past travels")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        showManualImport = true
                    }) {
                        HStack {
                            Label("Add Record Manually", systemImage: "plus.circle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("Manually add a record by selecting a location and date")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // MARK: - Actions Section
                Section {
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }

                    Button("Consolidate Records") {
                        showConsolidateAlert = true
                    }
                    .foregroundColor(.orange)

                    Button("Clear Records") {
                        showClearRecordsAlert = true
                    }
                    .foregroundColor(.red)
                }
                header: {
                    Text("Danger Zone")
                }
                footer: {
                    Text("Consolidate keeps only the most extreme record for each type/timeframe. Clear Records permanently deletes all data locally and from iCloud.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showConsolidateAlert) {
                Alert(
                    title: Text("Consolidate Records?"),
                    message: Text("This will remove all non-extreme records from your history, keeping only the best record for each type/timeframe combination.\n\nFor example, if you reached 42.5° North, then 42.6°, then 42.4°, only the 42.6° record will be kept.\n\nThis affects both local and iCloud data."),
                    primaryButton: .default(Text("Consolidate")) {
                        let removed = RecordHistoryManager.shared.consolidateRecords()
                        if removed > 0 {
                            consolidateResultMessage = "Successfully removed \(removed) non-extreme record\(removed == 1 ? "" : "s") from history."
                        } else {
                            consolidateResultMessage = "No records needed consolidation. All records are already extreme values!"
                        }
                        showConsolidateResult = true
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert("Consolidation Complete", isPresented: $showConsolidateResult) {
                Button("OK") {}
            } message: {
                Text(consolidateResultMessage)
            }
            .alert(isPresented: $showClearRecordsAlert) {
                Alert(
                    title: Text("⚠️ Clear All Records"),
                    message: Text("This will PERMANENTLY delete all your records including:\n\n• All 7 geographical records\n• Complete history log\n• All associated photos\n\nThis affects both local and iCloud data.\n\nThis action CANNOT be undone."),
                    primaryButton: .destructive(Text("Delete Everything")) {
                        RecordHistoryManager.shared.clearHistory()
                        // Reset setup flag to show wizard
                        settings.hasCompletedSetup = false
                        settings.saveSettings()
                        showSetupWizard = true
                    },
                    secondaryButton: .cancel()
                )
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
