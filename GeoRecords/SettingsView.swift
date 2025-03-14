import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    
    // State for Home Address if needed
    @State private var homeAddressString: String = ""
    // State for Clear History confirmation.
    @State private var showClearHistoryAlert = false
    
    // Available options for Latitude/Longitude deltas.
    let deltaOptions: [Double] = [0.1, 0.2, 0.5, 1.0, 2.0, 5.0]
    // Available options for Altitude delta.
    let altitudeOptions: [Double] = [100, 200, 500, 1000]
    
    var body: some View {
        NavigationView {
            Form {
                // MARK: - Notifications Section
                Section(header: Text("Notifications")) {
                    Toggle("Notify on New Record", isOn: $settings.notifyOnNewRecord)
                        .onChange(of: settings.notifyOnNewRecord) { _ in
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
                    .onChange(of: settings.unitSystem) { _ in
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
                    
                    Picker("Longitude Δ (deg)", selection: $settings.minLongitudeDelta) {
                        ForEach(deltaOptions, id: \.self) { value in
                            Text(String(format: "%.1f", value))
                                .tag(value)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    
                    Picker("Altitude Δ (\(settings.unitSystem == .imperial ? "ft" : "m"))", selection: $settings.minAltitudeDeltaFeet) {
                        ForEach(altitudeOptions, id: \.self) { value in
                            Text("\(Int(value))")
                                .tag(value)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                // MARK: - Timer Interval Section
                Section(header: Text("Timer Interval")) {
                    VStack {
                        Slider(value: $settings.timerInterval, in: 10...600, step: 1)
                            .onChange(of: settings.timerInterval) { _ in
                                settings.saveSettings()
                            }
                        Text("Current: \(Int(settings.timerInterval)) seconds")
                    }
                }
                
                // MARK: - Home Location Section
                Section(header: Text("Home Location")) {
                    NavigationLink(destination: HomePickerView()) {
                        HStack {
                            Text("Home")
                            Spacer()
                            if let coord = settings.homeCoordinate {
                                Text("(\(coord.latitude, specifier: "%.4f"), \(coord.longitude, specifier: "%.4f"))")
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Not set")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
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
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showClearHistoryAlert) {
                Alert(
                    title: Text("Clear History"),
                    message: Text("Are you sure you want to clear all history? This action cannot be undone."),
                    primaryButton: .destructive(Text("Clear")) {
                        RecordHistoryManager.shared.clearHistory()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}
