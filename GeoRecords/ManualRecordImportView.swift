import SwiftUI
import MapKit
import CoreLocation
import PhotosUI

struct ManualRecordImportView: View {
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var selectedRecordType: String = "Furthest North"
    @State private var selectedDate = Date()
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showConfirmation = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showNoLocationAlert = false

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
                Button("Add Record") {
                    addRecord()
                }
            } message: {
                if let location = selectedLocation {
                    Text("Add \(selectedRecordType) record at \(formatValue(for: selectedRecordType, location: location))?")
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

        // Get current month and year boundaries
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let startOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now

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
        if let existing = existing {
            switch recordType {
            case "Furthest North", "Furthest East", "Furthest Up", "Furthest from Home":
                shouldUpdate = detail.value > existing.value  // Higher is better
            case "Furthest South", "Furthest West", "Furthest Down":
                shouldUpdate = detail.value < existing.value  // Lower is better
            default:
                shouldUpdate = false
            }
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
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                ))
            }
        } catch {
            await MainActor.run {
                showNoLocationAlert = true
            }
        }
    }
}

// MARK: - Coordinate Picker View
struct CoordinatePickerView: View {
    @Binding var coordinate: CLLocationCoordinate2D?
    @Binding var mapPosition: MapCameraPosition
    @Environment(\.dismiss) var dismiss

    @State private var inputMode: InputMode = .search
    @State private var locationSearchText = ""
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSearching = false
    @State private var searchResults: [CLPlacemark] = []

    enum InputMode: String, CaseIterable {
        case search = "Search"
        case coordinates = "Coordinates"
    }

    var body: some View {
        Form {
            Section {
                Picker("Input Method", selection: $inputMode) {
                    ForEach(InputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if inputMode == .search {
                Section(header: Text("Search for Location")) {
                    TextField("Enter city, address, or place name", text: $locationSearchText)
                        .autocapitalization(.words)
                        .onChange(of: locationSearchText) { oldValue, newValue in
                            // Clear results when user types
                            searchResults = []
                        }

                    Text("Example: \"Paris, France\" or \"Eiffel Tower\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button(action: {
                        searchLocation()
                    }) {
                        if isSearching {
                            HStack {
                                Spacer()
                                ProgressView()
                                Text("Searching...")
                                    .padding(.leading, 8)
                                Spacer()
                            }
                        } else {
                            Text("Search")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(locationSearchText.isEmpty || isSearching)
                }

                if !searchResults.isEmpty {
                    Section(header: Text("Search Results")) {
                        ForEach(searchResults.indices, id: \.self) { index in
                            Button(action: {
                                selectLocation(searchResults[index])
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(formatPlacemarkName(searchResults[index]))
                                        .foregroundColor(.primary)
                                    if let subtitle = formatPlacemarkSubtitle(searchResults[index]) {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
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
                    .disabled(latitudeText.isEmpty || longitudeText.isEmpty)
                }
            }
        }
        .navigationTitle("Enter Location")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func searchLocation() {
        isSearching = true
        searchResults = []
        let geocoder = CLGeocoder()

        geocoder.geocodeAddressString(locationSearchText) { placemarks, error in
            isSearching = false

            if let error = error {
                errorMessage = "Could not find location: \(error.localizedDescription)"
                showError = true
                return
            }

            guard let placemarks = placemarks, !placemarks.isEmpty else {
                errorMessage = "No results found for '\(locationSearchText)'"
                showError = true
                return
            }

            searchResults = placemarks
        }
    }

    private func selectLocation(_ placemark: CLPlacemark) {
        guard let location = placemark.location else { return }

        let newCoordinate = location.coordinate
        coordinate = newCoordinate
        mapPosition = .region(MKCoordinateRegion(
            center: newCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))

        dismiss()
    }

    private func formatPlacemarkName(_ placemark: CLPlacemark) -> String {
        if let name = placemark.name {
            return name
        }
        if let locality = placemark.locality {
            return locality
        }
        return "Unknown Location"
    }

    private func formatPlacemarkSubtitle(_ placemark: CLPlacemark) -> String? {
        var components: [String] = []

        if let locality = placemark.locality, placemark.name != locality {
            components.append(locality)
        }
        if let adminArea = placemark.administrativeArea {
            components.append(adminArea)
        }
        if let country = placemark.country {
            components.append(country)
        }

        return components.isEmpty ? nil : components.joined(separator: ", ")
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
