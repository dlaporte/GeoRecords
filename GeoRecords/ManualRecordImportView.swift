import SwiftUI
import MapKit
import CoreLocation
import PhotosUI

struct ManualRecordImportView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var selectedRecordType: String = RecordType.north.rawValue
    @State private var selectedDate = Date()
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showConfirmation = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showNoLocationAlert = false
    @State private var locationName: String?
    @State private var isGeocodingLocation = false
    @State private var altitudeText: String = ""
    @State private var selectedPhotoAssetIdentifier: String?
    @State private var selectedPhotoCloudIdentifier: String?
    @State private var selectedPhotoImage: UIImage?
    @State private var recordTypesThatWouldBeat: [String] = []

    private var recordTypes: [String] {
        // If we have a location and filtered types, show only those
        if selectedLocation != nil && !recordTypesThatWouldBeat.isEmpty {
            return recordTypesThatWouldBeat
        }
        // Otherwise show all types
        return RecordType.allTypeStrings
    }

    private var isAltitudeRecord: Bool {
        selectedRecordType == RecordType.up.rawValue
    }

    private var confirmButtonTitle: String {
        recordsToReplace.isEmpty ? "Add Record" : "Replace Record"
    }

    private var confirmationMessage: String {
        guard let location = selectedLocation else { return "" }

        if recordsToReplace.isEmpty {
            return "Add \(selectedRecordType) record at \(previewValue(for: selectedRecordType, location: location))?"
        } else {
            let timeFramesText = recordsToReplace.map { $0.0.rawValue }.joined(separator: ", ")
            guard let oldestRecord = recordsToReplace.last?.1 else { return "" }
            let dateText = mediumDateFormatter.string(from: oldestRecord.timestamp)
            return "This will replace your \(selectedRecordType) record(s) for: \(timeFramesText).\n\nCurrent record from \(dateText) will be moved to history."
        }
    }

    private var altitudeUnitLabel: String {
        settings.unitSystem == .imperial ? "ft" : "m"
    }

    private var parsedAltitude: Double? {
        guard let altitude = Double(altitudeText) else { return nil }
        // Convert to meters for storage if imperial
        if settings.unitSystem == .imperial {
            return altitude / metersToFeet
        }
        return altitude
    }

    // Check which existing records will be replaced
    private var recordsToReplace: [(TimeFrame, RecordDetail)] {
        guard let location = selectedLocation,
              let recordType = RecordType.from(string: selectedRecordType) else { return [] }

        let value: Double
        switch recordType {
        case .north, .south:
            value = location.latitude
        case .east, .west:
            value = location.longitude
        case .up:
            guard let altitude = parsedAltitude else { return [] }
            value = altitude
        case .fromHome:
            guard let homeCoord = settings.homeCoordinate else { return [] }
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let recordLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let distanceMeters = recordLocation.distance(from: homeLocation)
            value = distanceMeters  // Store in meters (converted to display units in UI)
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
            if let existing = recordManager.getRecord(type: selectedRecordType, timeFrame: timeFrame) {
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
            contentView
        }
    }

    private var contentView: some View {
        mainContent
            .navigationTitle("Add Individual Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .modifier(alertsModifier)
            .modifier(photoPickerModifier)
            .modifier(locationChangeModifier)
    }

    private var alertsModifier: some ViewModifier {
        AlertsModifier(
            showConfirmation: $showConfirmation,
            showNoLocationAlert: $showNoLocationAlert,
            confirmButtonTitle: confirmButtonTitle,
            confirmationMessage: confirmationMessage,
            addRecord: addRecord
        )
    }

    private var photoPickerModifier: some ViewModifier {
        PhotoPickerModifier(
            showPhotoPicker: $showPhotoPicker,
            selectedPhotoItem: $selectedPhotoItem,
            onPhotoSelected: {
                Task { await loadPhotoLocation() }
            }
        )
    }

    private var locationChangeModifier: some ViewModifier {
        LocationChangeModifier(
            selectedLocation: $selectedLocation,
            altitudeText: $altitudeText,
            locationName: locationName,
            isGeocodingLocation: isGeocodingLocation,
            onLocationChange: { coord in
                if locationName == nil && !isGeocodingLocation {
                    geocodeLocation(coord)
                }
                checkRecordsThatWouldBeat(location: coord)
            },
            onLocationCleared: {
                recordTypesThatWouldBeat = []
            },
            onAltitudeChange: {
                if let location = selectedLocation {
                    checkRecordsThatWouldBeat(location: location)
                }
            }
        )
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            mapSection
            formSection
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Add") { showConfirmation = true }
                .disabled(selectedLocation == nil || (isAltitudeRecord && parsedAltitude == nil))
        }
    }

    @ViewBuilder
    private var confirmationAlertButtons: some View {
        Button("Cancel", role: .cancel) {}
        Button(confirmButtonTitle) { addRecord() }
    }

    // MARK: - View Sections

    private var mapSection: some View {
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
                    locationName = nil
                    withAnimation {
                        selectedLocation = coordinate
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: useCurrentLocation) {
                Image(systemName: "location.fill")
                    .padding(12)
                    .background(Color(UIColor.systemBackground))
                    .clipShape(Circle())
                    .shadow(radius: 2)
            }
            .padding()
        }
    }

    private var formSection: some View {
        Form {
            locationSection
            altitudeSectionIfNeeded
            recordDetailsSection
            previewSection
        }
    }

    @ViewBuilder
    private var altitudeSectionIfNeeded: some View {
        if isAltitudeRecord {
            altitudeSection
        }
    }

    private var locationSection: some View {
        Section(header: Text("Location")) {
            locationDetails
            Button("Import from Photo") {
                showPhotoPicker = true
            }
            NavigationLink(destination: CoordinatePickerView(coordinate: $selectedLocation, mapPosition: $mapPosition)) {
                Text("Enter Location Manually")
            }
        }
    }

    @ViewBuilder
    private var locationDetails: some View {
        if let location = selectedLocation {
            locationNameRow
            latitudeRow(location)
            longitudeRow(location)
        } else {
            Text("Tap the map above to select a location")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }

    private var locationNameRow: some View {
        HStack {
            Text("Location:")
            Spacer()
            locationNameValue
        }
    }

    @ViewBuilder
    private var locationNameValue: some View {
        if isGeocodingLocation {
            ProgressView()
                .scaleEffect(0.8)
        } else {
            Text(locationName ?? "Unknown")
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func latitudeRow(_ location: CLLocationCoordinate2D) -> some View {
        HStack {
            Text("Latitude:")
            Spacer()
            Text(String(format: "%.6f°", location.latitude))
                .foregroundColor(.secondary)
        }
    }

    private func longitudeRow(_ location: CLLocationCoordinate2D) -> some View {
        HStack {
            Text("Longitude:")
            Spacer()
            Text(String(format: "%.6f°", location.longitude))
                .foregroundColor(.secondary)
        }
    }

    private var altitudeSection: some View {
        Section(header: Text("Altitude")) {
            HStack {
                TextField("Enter altitude", text: $altitudeText)
                    .keyboardType(.decimalPad)
                Text(altitudeUnitLabel)
                    .foregroundColor(.secondary)
            }
            Text("Enter the altitude in \(settings.unitSystem == .imperial ? "feet" : "meters")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var recordDetailsSection: some View {
        Section(header: Text("Record Details")) {
            Picker("Record Type", selection: $selectedRecordType) {
                ForEach(recordTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
            }

            DatePicker("Date", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
        }
    }

    private var previewSection: some View {
        Section(header: Text("Preview")) {
            previewContent
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let location = selectedLocation {
            // Photo thumbnail if available
            if let photo = selectedPhotoImage {
                HStack {
                    Text("Photo:")
                    Spacer()
                    Image(uiImage: photo)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Show warning if no records would be beaten
            if recordTypesThatWouldBeat.isEmpty {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.orange)
                    Text("This location doesn't beat any current records")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            HStack {
                Text("Value:")
                Spacer()
                Text(previewValue(for: selectedRecordType, location: location))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helper Functions

    private func useCurrentLocation() {
        if let userLocation = LocationManager.shared.currentLocation {
            locationName = nil
            selectedLocation = userLocation.coordinate
            mapPosition = .region(MKCoordinateRegion(
                center: userLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
            ))
        }
    }

    private func previewValue(for recordType: String, location: CLLocationCoordinate2D) -> String {
        // Handle altitude records with user input
        if recordType == RecordType.up.rawValue {
            if let altitude = parsedAltitude {
                // Display in user's preferred units
                if settings.unitSystem == .imperial {
                    return FormatUtils.formatFeet(altitude * metersToFeet)
                } else {
                    return FormatUtils.formatMeters(altitude)
                }
            } else {
                return "Enter altitude above"
            }
        }

        // Use standard formatting for other record types
        return FormatUtils.formatRecordValue(
            for: recordType,
            at: location,
            homeCoordinate: settings.homeCoordinate,
            unitSystem: settings.unitSystem
        )
    }

    private func addRecord() {
        guard let location = selectedLocation,
              let recordType = RecordType.from(string: selectedRecordType) else { return }

        let value: Double
        let altitude: Double

        switch recordType {
        case .north, .south:
            value = location.latitude
            altitude = 0
        case .east, .west:
            value = location.longitude
            altitude = 0
        case .up:
            guard let manualAltitude = parsedAltitude else { return }
            value = manualAltitude  // Already in meters
            altitude = manualAltitude
        case .fromHome:
            guard let homeCoord = settings.homeCoordinate else { return }
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let recordLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let distanceMeters = recordLocation.distance(from: homeLocation)
            value = distanceMeters  // Store in meters
            altitude = 0
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

        // Track if we've saved thumbnail (only need once)
        var thumbnailSaved = false

        // Create records for each applicable timeframe
        for timeFrame in timeFrames {
            let detail = RecordDetail(
                value: value,
                timestamp: selectedDate,
                coordinate: location,
                altitude: altitude,
                locationName: locationName,
                recordType: selectedRecordType,
                timeFrame: timeFrame,
                photoAssetIdentifier: selectedPhotoAssetIdentifier,
                photoCloudIdentifier: selectedPhotoCloudIdentifier
            )

            // Update record manager (uses shared method that checks if new value is better)
            RecordManager.shared.updateRecordIfBetter(recordType: selectedRecordType, detail: detail, timeFrame: timeFrame)

            // Save to Core Data
            RecordHistoryManager.shared.addRecord(recordType: selectedRecordType, detail: detail)

            // Save thumbnail to cache (once per photo, for widget and fast loading)
            if !thumbnailSaved, let image = selectedPhotoImage {
                ThumbnailCache.shared.saveThumbnail(from: image, for: detail.id)
                thumbnailSaved = true
            }
        }

        dismiss()
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

            // Get photo asset identifier
            let assetIdentifier = item.itemIdentifier

            // Get cloud identifier for cross-device access
            var cloudIdentifier: String?
            if let localId = assetIdentifier {
                cloudIdentifier = await getCloudIdentifier(for: localId)
            }

            // Create a UIImage from the data for thumbnail
            let thumbnailImage = UIImage(data: data)

            // Update UI on main thread
            await MainActor.run {
                locationName = nil  // Reset so onChange triggers geocoding
                selectedLocation = coordinate
                selectedDate = photoDate
                selectedPhotoAssetIdentifier = assetIdentifier
                selectedPhotoCloudIdentifier = cloudIdentifier
                selectedPhotoImage = thumbnailImage
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

    private func geocodeLocation(_ coordinate: CLLocationCoordinate2D) {
        // Reset location name and start loading
        locationName = nil
        isGeocodingLocation = true

        // First check if we have a cached name for nearby coordinates
        if let cachedName = RecordHistoryManager.shared.lookupLocationName(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) {
            locationName = cachedName
            isGeocodingLocation = false
            return
        }

        // Otherwise, use Apple's geocoder
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = CLGeocoder()

        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            DispatchQueue.main.async {
                isGeocodingLocation = false

                if let error = error {
                    debugLog("Geocoding error: \(error.localizedDescription)")
                    locationName = unknownLocationString
                } else if let placemark = placemarks?.first {
                    locationName = FormatUtils.formatPlacemarkName(placemark)
                } else {
                    locationName = unknownLocationString
                }
            }
        }
    }

    private func checkRecordsThatWouldBeat(location: CLLocationCoordinate2D) {
        var wouldBeat: [String] = []

        // Get current month and year boundaries
        let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

        // Determine which timeframes apply to the selected date
        let appliesToAllTime = true
        let appliesToYear = selectedDate >= startOfYear
        let appliesToMonth = selectedDate >= startOfMonth

        // Check each record type
        for recordType in RecordType.allCases {
            let typeString = recordType.rawValue
            var beatsAny = false

            // Check if it beats all-time
            if appliesToAllTime, let currentRecord = recordManager.getRecord(type: typeString, timeFrame: .allTime) {
                if wouldBeatRecord(newLocation: location, recordType: recordType, currentValue: currentRecord.value) {
                    beatsAny = true
                }
            } else if appliesToAllTime && recordManager.getRecord(type: typeString, timeFrame: .allTime) == nil {
                // No record exists yet
                beatsAny = true
            }

            // Check if it beats yearly
            if !beatsAny && appliesToYear, let currentRecord = recordManager.getRecord(type: typeString, timeFrame: .year) {
                if wouldBeatRecord(newLocation: location, recordType: recordType, currentValue: currentRecord.value) {
                    beatsAny = true
                }
            } else if !beatsAny && appliesToYear && recordManager.getRecord(type: typeString, timeFrame: .year) == nil {
                beatsAny = true
            }

            // Check if it beats monthly
            if !beatsAny && appliesToMonth, let currentRecord = recordManager.getRecord(type: typeString, timeFrame: .month) {
                if wouldBeatRecord(newLocation: location, recordType: recordType, currentValue: currentRecord.value) {
                    beatsAny = true
                }
            } else if !beatsAny && appliesToMonth && recordManager.getRecord(type: typeString, timeFrame: .month) == nil {
                beatsAny = true
            }

            if beatsAny {
                wouldBeat.append(typeString)
            }
        }

        recordTypesThatWouldBeat = wouldBeat

        // Auto-select the first one if we have any
        if !wouldBeat.isEmpty && !wouldBeat.contains(selectedRecordType) {
            selectedRecordType = wouldBeat[0]
        }
    }

    private func wouldBeatRecord(newLocation: CLLocationCoordinate2D, recordType: RecordType, currentValue: Double) -> Bool {
        let newValue: Double

        switch recordType {
        case .north:
            newValue = newLocation.latitude
        case .south:
            newValue = newLocation.latitude
        case .east:
            newValue = newLocation.longitude
        case .west:
            newValue = newLocation.longitude
        case .up:
            // For altitude, we need user input - can't check without it
            return parsedAltitude != nil
        case .fromHome:
            guard let homeCoord = settings.homeCoordinate else { return false }
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let recordLocation = CLLocation(latitude: newLocation.latitude, longitude: newLocation.longitude)
            newValue = recordLocation.distance(from: homeLocation)
        }

        return recordType.shouldReplace(newValue: newValue, oldValue: currentValue)
    }

    /// Get the iCloud identifier for a photo asset (for cross-device access)
    private func getCloudIdentifier(for localIdentifier: String) async -> String? {
        // cloudIdentifierMappings(forLocalIdentifiers:) is synchronous in iOS 16+
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [localIdentifier])

        guard let mapping = mappings[localIdentifier] else {
            return nil
        }

        switch mapping {
        case .success(let cloudId):
            return cloudId.stringValue
        case .failure(let error):
            debugLog("⚠️ Failed to get cloud identifier: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Alerts Modifier

private struct AlertsModifier: ViewModifier {
    @Binding var showConfirmation: Bool
    @Binding var showNoLocationAlert: Bool
    let confirmButtonTitle: String
    let confirmationMessage: String
    let addRecord: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Add Record?", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button(confirmButtonTitle) { addRecord() }
            } message: {
                Text(confirmationMessage)
            }
            .alert("No Location Data", isPresented: $showNoLocationAlert) {
                Button("OK") {}
            } message: {
                Text("The selected photo does not contain GPS location information.")
            }
    }
}

// MARK: - Photo Picker Modifier

private struct PhotoPickerModifier: ViewModifier {
    @Binding var showPhotoPicker: Bool
    @Binding var selectedPhotoItem: PhotosPickerItem?
    let onPhotoSelected: () -> Void

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) { _, _ in
                onPhotoSelected()
            }
    }
}

// MARK: - Location Change Modifier

private struct LocationChangeModifier: ViewModifier {
    @Binding var selectedLocation: CLLocationCoordinate2D?
    @Binding var altitudeText: String
    let locationName: String?
    let isGeocodingLocation: Bool
    let onLocationChange: (CLLocationCoordinate2D) -> Void
    let onLocationCleared: () -> Void
    let onAltitudeChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedLocation?.latitude) { _, _ in
                handleLocationChange()
            }
            .onChange(of: selectedLocation?.longitude) { _, _ in
                handleLocationChange()
            }
            .onChange(of: altitudeText) { _, _ in
                onAltitudeChange()
            }
    }

    private func handleLocationChange() {
        if let coord = selectedLocation {
            onLocationChange(coord)
        } else {
            onLocationCleared()
        }
    }
}
