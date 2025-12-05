import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @StateObject private var photoScanner = PhotoLibraryScanner()

    // State for Clear History confirmation.
    @State private var showClearHistoryAlert = false
    @State private var showClearHistoryConfirmation = false
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
                Section(header: Text("Notifications")) {
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

                    Button("Clear History") {
                        showClearHistoryAlert = true
                    }
                    .foregroundColor(.red)
                }
                header: {
                    Text("Danger Zone")
                }
                footer: {
                    Text("Clearing history will permanently delete all recorded data and reset all your geographical records. This action cannot be undone.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showClearHistoryAlert) {
                Alert(
                    title: Text("⚠️ Clear All History"),
                    message: Text("This will PERMANENTLY delete all your records including:\n\n• All 7 geographical records\n• Complete history log\n• All associated photos\n\nThis action CANNOT be undone.\n\nType DELETE below to confirm."),
                    primaryButton: .destructive(Text("Clear Everything")) {
                        showClearHistoryConfirmation = true
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert("Final Confirmation", isPresented: $showClearHistoryConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Yes, Delete Everything", role: .destructive) {
                    RecordHistoryManager.shared.clearHistory()
                    // Reset setup flag to show wizard
                    settings.hasCompletedSetup = false
                    settings.saveSettings()
                    showSetupWizard = true
                }
            } message: {
                Text("Are you absolutely sure? All your geographical records and history will be permanently deleted.")
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
