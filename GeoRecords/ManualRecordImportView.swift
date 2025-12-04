import SwiftUI
import MapKit
import CoreLocation

struct ManualRecordImportView: View {
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var selectedRecordType: String = "Furthest North"
    @State private var selectedDate = Date()
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showConfirmation = false

    let recordTypes = [
        "Furthest North",
        "Furthest South",
        "Furthest East",
        "Furthest West",
        "Furthest Up",
        "Furthest Down",
        "Furthest from Home"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Map
                MapReader { reader in
                    Map(position: $mapPosition) {
                        if let location = selectedLocation {
                            Marker("Selected Location", coordinate: location)
                                .tint(.blue)
                        }
                    }
                    .frame(height: 300)
                    .onTapGesture { position in
                        if let coordinate = reader.convert(position, from: .local) {
                            withAnimation {
                                selectedLocation = coordinate
                            }
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    VStack(spacing: 8) {
                        Button(action: {
                            if let userLocation = LocationManager.shared.currentLocation {
                                selectedLocation = userLocation.coordinate
                                mapPosition = .region(MKCoordinateRegion(
                                    center: userLocation.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                                ))
                            }
                        }) {
                            Image(systemName: "location.fill")
                                .padding(12)
                                .background(Color(UIColor.systemBackground))
                                .clipShape(Circle())
                                .shadow(radius: 2)
                        }
                    }
                    .padding()
                }

                // Form
                Form {
                    Section(header: Text("Location")) {
                        if let location = selectedLocation {
                            HStack {
                                Text("Latitude:")
                                Spacer()
                                Text(String(format: "%.6f°", location.latitude))
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Longitude:")
                                Spacer()
                                Text(String(format: "%.6f°", location.longitude))
                                    .foregroundColor(.secondary)
                            }

                            Button("Change Location") {
                                // Show coordinate picker
                            }
                        } else {
                            Button("Select Location on Map") {
                                // Instruction to tap map
                            }
                            .foregroundColor(.blue)
                        }

                        NavigationLink(destination: CoordinatePickerView(coordinate: $selectedLocation, mapPosition: $mapPosition)) {
                            Text("Enter Coordinates Manually")
                        }
                    }

                    Section(header: Text("Record Details")) {
                        Picker("Record Type", selection: $selectedRecordType) {
                            ForEach(recordTypes, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }

                        DatePicker("Date", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                    }

                    Section(header: Text("Preview")) {
                        if let location = selectedLocation {
                            HStack {
                                Text("Value:")
                                Spacer()
                                Text(formatValue(for: selectedRecordType, location: location))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Record Manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        showConfirmation = true
                    }
                    .disabled(selectedLocation == nil)
                }
            }
            .alert("Add Record?", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Add Record") {
                    addRecord()
                }
            } message: {
                if let location = selectedLocation {
                    Text("Add \(selectedRecordType) record at \(formatValue(for: selectedRecordType, location: location))?")
                }
            }
        }
    }

    private func formatValue(for recordType: String, location: CLLocationCoordinate2D) -> String {
        switch recordType {
        case "Furthest North":
            return String(format: "%.4f°", location.latitude)
        case "Furthest South":
            return String(format: "%.4f°", location.latitude)
        case "Furthest East":
            return String(format: "%.4f°", location.longitude)
        case "Furthest West":
            return String(format: "%.4f°", location.longitude)
        case "Furthest Up", "Furthest Down":
            return "Altitude not available for manual entry"
        case "Furthest from Home":
            if let homeCoord = settings.homeCoordinate {
                let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
                let recordLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
                let distance = recordLocation.distance(from: homeLocation)
                if settings.unitSystem == .imperial {
                    let miles = distance / 1609.344
                    return String(format: "%.2f mi", miles)
                } else {
                    let km = distance / 1000.0
                    return String(format: "%.2f km", km)
                }
            }
            return "Set home location first"
        default:
            return ""
        }
    }

    private func addRecord() {
        guard let location = selectedLocation else { return }

        let value: Double
        let altitude: Double = 0 // Manual entry doesn't include altitude

        switch selectedRecordType {
        case "Furthest North", "Furthest South":
            value = location.latitude
        case "Furthest East", "Furthest West":
            value = location.longitude
        case "Furthest Up", "Furthest Down":
            value = 0 // Can't manually enter altitude
            return // Skip altitude records for manual entry
        case "Furthest from Home":
            if let homeCoord = settings.homeCoordinate {
                let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
                let recordLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
                let distanceMeters = recordLocation.distance(from: homeLocation)
                value = distanceMeters * 3.28084 // Convert to feet for storage
            } else {
                return // No home location set
            }
        default:
            return
        }

        let detail = RecordDetail(
            value: value,
            timestamp: selectedDate,
            coordinate: location,
            altitude: altitude,
            locationName: nil,
            recordType: selectedRecordType,
            photoData: nil
        )

        // Update record manager
        updateRecordManager(recordType: selectedRecordType, detail: detail)

        // Save to Core Data
        RecordHistoryManager.shared.addRecord(recordType: selectedRecordType, detail: detail)

        dismiss()
    }

    private func updateRecordManager(recordType: String, detail: RecordDetail) {
        let recordManager = RecordManager.shared

        switch recordType {
        case "Furthest North":
            if let existing = recordManager.furthestNorth {
                if detail.value > existing.value {
                    recordManager.furthestNorth = detail
                }
            } else {
                recordManager.furthestNorth = detail
            }
        case "Furthest South":
            if let existing = recordManager.furthestSouth {
                if detail.value < existing.value {
                    recordManager.furthestSouth = detail
                }
            } else {
                recordManager.furthestSouth = detail
            }
        case "Furthest East":
            if let existing = recordManager.furthestEast {
                if detail.value > existing.value {
                    recordManager.furthestEast = detail
                }
            } else {
                recordManager.furthestEast = detail
            }
        case "Furthest West":
            if let existing = recordManager.furthestWest {
                if detail.value < existing.value {
                    recordManager.furthestWest = detail
                }
            } else {
                recordManager.furthestWest = detail
            }
        case "Furthest from Home":
            if let existing = recordManager.furthestFromHome {
                if detail.value > existing.value {
                    recordManager.furthestFromHome = detail
                }
            } else {
                recordManager.furthestFromHome = detail
            }
        default:
            break
        }
    }
}

// MARK: - Coordinate Picker View
struct CoordinatePickerView: View {
    @Binding var coordinate: CLLocationCoordinate2D?
    @Binding var mapPosition: MapCameraPosition
    @Environment(\.dismiss) var dismiss

    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        Form {
            Section(header: Text("Enter Coordinates")) {
                HStack {
                    Text("Latitude:")
                    TextField("40.7128", text: $latitudeText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("Longitude:")
                    TextField("-74.0060", text: $longitudeText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                }

                Text("Latitude range: -90 to 90")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Longitude range: -180 to 180")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Set Location") {
                    validateAndSet()
                }
            }
        }
        .navigationTitle("Enter Coordinates")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Invalid Coordinates", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func validateAndSet() {
        guard let lat = Double(latitudeText), let lon = Double(longitudeText) else {
            errorMessage = "Please enter valid numbers for latitude and longitude"
            showError = true
            return
        }

        guard lat >= -90 && lat <= 90 else {
            errorMessage = "Latitude must be between -90 and 90"
            showError = true
            return
        }

        guard lon >= -180 && lon <= 180 else {
            errorMessage = "Longitude must be between -180 and 180"
            showError = true
            return
        }

        let newCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        coordinate = newCoordinate
        mapPosition = .region(MKCoordinateRegion(
            center: newCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))

        dismiss()
    }
}
