import SwiftUI
import MapKit
import CoreLocation
import PhotosUI

struct ManualRecordImportView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var selectedRecordType: String = "Furthest North"
    @State private var selectedDate = Date()
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showConfirmation = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showNoLocationAlert = false

    let recordTypes = RecordType.allTypeStrings

    // Check which existing records will be replaced
    private var recordsToReplace: [(TimeFrame, RecordDetail)] {
        guard let location = selectedLocation else { return [] }

        let value: Double
        switch selectedRecordType {
        case "Furthest North", "Furthest South":
            value = location.latitude
        case "Furthest East", "Furthest West":
            value = location.longitude
        case "Furthest Up", "Furthest Down":
            return [] // Can't manually enter altitude
        case "Furthest from Home":
            guard let homeCoord = settings.homeCoordinate else { return [] }
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let recordLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let distanceMeters = recordLocation.distance(from: homeLocation)
            value = distanceMeters * metersToFeet // Convert to feet for storage
        default:
            return []
        }

        // Get current month and year boundaries
        let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

        // Determine which timeframes this record belongs to
        let timeFrames: [TimeFrame]
        if selectedDate >= startOfMonth {
            timeFrames = [.month, .year, .allTime]
        } else if selectedDate >= startOfYear {
            timeFrames = [.year, .allTime]
        } else {
            timeFrames = [.allTime]
        }

        // Check which existing records would be replaced
        var replacements: [(TimeFrame, RecordDetail)] = []
        for timeFrame in timeFrames {
            if let existing = recordManager.getRecord(type: selectedRecordType, timeFrame: timeFrame),
               let recordType = RecordType.from(string: selectedRecordType) {
                let wouldReplace = recordType.shouldReplace(newValue: value, oldValue: existing.value)
                if wouldReplace {
                    replacements.append((timeFrame, existing))
                }
            }
        }

        return replacements
    }

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
                                    span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
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
                        } else {
                            Text("Tap the map above to select a location")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }

                        Button("Import Location from Photo") {
                            showPhotoPicker = true
                        }

                        NavigationLink(destination: CoordinatePickerView(coordinate: $selectedLocation, mapPosition: $mapPosition)) {
                            Text("Enter Location Manually")
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
                Button(recordsToReplace.isEmpty ? "Add Record" : "Replace Record") {
                    addRecord()
                }
            } message: {
                if let location = selectedLocation {
                    if recordsToReplace.isEmpty {
                        Text("Add \(selectedRecordType) record at \(formatValue(for: selectedRecordType, location: location))?")
                    } else {
                        let timeFramesText = recordsToReplace.map { $0.0.rawValue }.joined(separator: ", ")
                        let oldestRecord = recordsToReplace.last!.1
                        let dateText = mediumDateFormatter.string(from: oldestRecord.timestamp)

                        Text("This will replace your \(selectedRecordType) record(s) for: \(timeFramesText).\n\nCurrent record from \(dateText) will be moved to history.")
                    }
                }
            }
            .alert("No Location Data", isPresented: $showNoLocationAlert) {
                Button("OK") {}
            } message: {
                Text("The selected photo does not contain GPS location information.")
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) { oldValue, newValue in
                Task {
                    await loadPhotoLocation()
                }
            }
        }
    }

    private func formatValue(for recordType: String, location: CLLocationCoordinate2D) -> String {
        return FormatUtils.formatRecordValue(
            for: recordType,
            at: location,
            homeCoordinate: settings.homeCoordinate,
            unitSystem: settings.unitSystem
        )
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
                value = distanceMeters * metersToFeet // Convert to feet for storage
            } else {
                return // No home location set
            }
        default:
            return
        }

        // Get current month and year boundaries
        let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

        // Determine which timeframes this record belongs to based on its timestamp
        let timeFrames: [TimeFrame]
        if selectedDate >= startOfMonth {
            timeFrames = [.month, .year, .allTime]  // This month = also this year and all-time
        } else if selectedDate >= startOfYear {
            timeFrames = [.year, .allTime]  // This year but not this month
        } else {
            timeFrames = [.allTime]  // Only all-time
        }

        // Create records for each applicable timeframe
        for timeFrame in timeFrames {
            let detail = RecordDetail(
                value: value,
                timestamp: selectedDate,
                coordinate: location,
                altitude: altitude,
                locationName: nil,
                recordType: selectedRecordType,
                timeFrame: timeFrame,
                photoData: nil
            )

            // Update record manager
            updateRecordManager(recordType: selectedRecordType, detail: detail, timeFrame: timeFrame)

            // Save to Core Data
            RecordHistoryManager.shared.addRecord(recordType: selectedRecordType, detail: detail)
        }

        dismiss()
    }

    private func updateRecordManager(recordType: String, detail: RecordDetail, timeFrame: TimeFrame) {
        let recordManager = RecordManager.shared
        let existing = recordManager.getRecord(type: recordType, timeFrame: timeFrame)

        // Determine if this record should replace the existing one
        let shouldUpdate: Bool
        if let existing = existing,
           let type = RecordType.from(string: recordType) {
            shouldUpdate = type.shouldReplace(newValue: detail.value, oldValue: existing.value)
        } else {
            shouldUpdate = true  // No existing record, so set it
        }

        if shouldUpdate {
            recordManager.setRecord(type: recordType, timeFrame: timeFrame, record: detail)
        }
    }

    private func loadPhotoLocation() async {
        guard let item = selectedPhotoItem else { return }

        do {
            // Load the image data
            guard let data = try await item.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    showNoLocationAlert = true
                }
                return
            }

            // Create image source from data
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                await MainActor.run {
                    showNoLocationAlert = true
                }
                return
            }

            // Get metadata from first image
            guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                await MainActor.run {
                    showNoLocationAlert = true
                }
                return
            }

            // Extract GPS data
            guard let gpsData = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any],
                  let latitude = gpsData[kCGImagePropertyGPSLatitude as String] as? Double,
                  let longitude = gpsData[kCGImagePropertyGPSLongitude as String] as? Double,
                  let latRef = gpsData[kCGImagePropertyGPSLatitudeRef as String] as? String,
                  let lonRef = gpsData[kCGImagePropertyGPSLongitudeRef as String] as? String else {
                await MainActor.run {
                    showNoLocationAlert = true
                }
                return
            }

            // Adjust coordinates based on hemisphere
            let finalLatitude = latRef == "S" ? -latitude : latitude
            let finalLongitude = lonRef == "W" ? -longitude : longitude
            let coordinate = CLLocationCoordinate2D(latitude: finalLatitude, longitude: finalLongitude)

            // Extract timestamp if available
            var photoDate = Date()
            if let exifData = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let dateString = exifData[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let date = formatter.date(from: dateString) {
                    photoDate = date
                }
            }

            // Update UI on main thread
            await MainActor.run {
                selectedLocation = coordinate
                selectedDate = photoDate
                mapPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
                ))
            }
        } catch {
            await MainActor.run {
                showNoLocationAlert = true
            }
        }
    }
}
