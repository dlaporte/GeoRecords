import SwiftUI
import MapKit
import CoreLocation
import PhotosUI

struct ManualRecordImportView: View {
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var selectedDate = Date()
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showNoLocationAlert = false
    @State private var locationName: String?
    @State private var isGeocodingLocation = false
    @State private var altitudeText: String = ""
    @State private var selectedPhotoAssetIdentifier: String?
    @State private var selectedPhotoCloudIdentifier: String?
    @State private var selectedPhotoImage: UIImage?
    @State private var isAdding = false
    @State private var showResultAlert = false
    @State private var resultMessage = ""

    private var altitudeUnitLabel: String {
        settings.unitSystem == .imperial ? "ft" : "m"
    }

    private var parsedAltitude: Double? {
        guard let altitude = Double(altitudeText), !altitudeText.isEmpty else { return nil }
        // Convert to meters for storage if imperial
        if settings.unitSystem == .imperial {
            return altitude / metersToFeet
        }
        return altitude
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapSection
                formSection
            }
            .navigationTitle("Add Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button("Add") { addLocation() }
                            .disabled(selectedLocation == nil)
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) { _, _ in
                Task { await loadPhotoLocation() }
            }
            .onChange(of: selectedLocation?.latitude) { _, _ in
                if let coord = selectedLocation {
                    if locationName == nil && !isGeocodingLocation {
                        geocodeLocation(coord)
                    }
                }
            }
            .onChange(of: selectedLocation?.longitude) { _, _ in
                if let coord = selectedLocation {
                    if locationName == nil && !isGeocodingLocation {
                        geocodeLocation(coord)
                    }
                }
            }
            .alert("No Location Data", isPresented: $showNoLocationAlert) {
                Button("OK") {}
            } message: {
                Text("The selected photo does not contain GPS location information.")
            }
            .alert("Location Added", isPresented: $showResultAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text(resultMessage)
            }
        }
    }

    // MARK: - View Sections

    private var mapSection: some View {
        MapReader { reader in
            Map(position: $mapPosition) {
                if let location = selectedLocation {
                    Marker("Selected Location", coordinate: location)
                        .tint(.orange)
                }
            }
            .frame(height: 280)
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
            altitudeSection
            dateSection
        }
    }

    private var locationSection: some View {
        Section(header: Text("Location")) {
            if let location = selectedLocation {
                HStack {
                    Text("Location:")
                    Spacer()
                    if isGeocodingLocation {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text(locationName ?? "Unknown")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
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

            Button("Import from Photo") {
                showPhotoPicker = true
            }

            NavigationLink(destination: CoordinatePickerView(coordinate: $selectedLocation, mapPosition: $mapPosition)) {
                Text("Enter Coordinates Manually")
            }
        }
    }

    private var altitudeSection: some View {
        Section(header: Text("Altitude (Optional)")) {
            HStack {
                TextField("Enter altitude", text: $altitudeText)
                    .keyboardType(.decimalPad)
                Text(altitudeUnitLabel)
                    .foregroundColor(.secondary)
            }
            Text("Leave blank if unknown. Used for 'Furthest Up' records.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var dateSection: some View {
        Section(header: Text("Date & Time")) {
            DatePicker("When", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
        }
    }

    // MARK: - Actions

    private func useCurrentLocation() {
        if let userLocation = LocationManager.shared.currentLocation {
            locationName = nil
            selectedLocation = userLocation.coordinate
            // Also set altitude if available
            if userLocation.altitude > 0 {
                let displayAltitude = settings.unitSystem == .imperial
                    ? userLocation.altitude * metersToFeet
                    : userLocation.altitude
                altitudeText = String(format: "%.0f", displayAltitude)
            }
            mapPosition = .region(MKCoordinateRegion(
                center: userLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
            ))
        }
    }

    private func addLocation() {
        guard let location = selectedLocation else { return }

        isAdding = true

        Task {
            // Track records by type -> timeframes
            var recordsByType: [String: [TimeFrame]] = [:]
            var regionsAdded: [String] = []

            // Get altitude (use 0 if not specified)
            let altitude = parsedAltitude ?? 0

            // Get time frame boundaries
            let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

            // Determine applicable timeframes based on date
            let timeFrames: [TimeFrame]
            if selectedDate >= startOfMonth {
                timeFrames = [.month, .year, .allTime]
            } else if selectedDate >= startOfYear {
                timeFrames = [.year, .allTime]
            } else {
                timeFrames = [.allTime]
            }

            // Check and add records for each type
            for recordType in RecordType.allCases {
                let value: Double
                var shouldCheck = true

                switch recordType {
                case .north, .south:
                    value = location.latitude
                case .east, .west:
                    value = location.longitude
                case .up:
                    // Only check altitude records if altitude was provided
                    if parsedAltitude != nil {
                        value = altitude
                    } else {
                        shouldCheck = false
                        value = 0
                    }
                case .fromHome:
                    if let homeCoord = settings.homeCoordinate {
                        let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
                        let recordLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
                        value = recordLocation.distance(from: homeLocation)
                    } else {
                        shouldCheck = false
                        value = 0
                    }
                case .state, .country, .continent:
                    // Region records are only created from actual visits via RegionTrackingManager
                    // Skip them in manual record import
                    shouldCheck = false
                    value = 0
                }

                guard shouldCheck else { continue }

                // Check each applicable timeframe
                for timeFrame in timeFrames {
                    let existingRecord = RecordManager.shared.getRecord(type: recordType.rawValue, timeFrame: timeFrame)

                    // Determine if this beats the existing record (or if no record exists)
                    let shouldAdd: Bool
                    if let existing = existingRecord {
                        shouldAdd = recordType.shouldReplace(newValue: value, oldValue: existing.value)
                    } else {
                        shouldAdd = true // No existing record
                    }

                    if shouldAdd {
                        let detail = RecordDetail(
                            value: value,
                            timestamp: selectedDate,
                            coordinate: location,
                            altitude: altitude,
                            locationName: locationName,
                            recordType: recordType.rawValue,
                            timeFrame: timeFrame,
                            photoAssetIdentifier: selectedPhotoAssetIdentifier,
                            photoCloudIdentifier: selectedPhotoCloudIdentifier
                        )

                        // Update in-memory and save to Core Data
                        RecordManager.shared.updateRecordIfBetter(
                            recordType: recordType.rawValue,
                            detail: detail,
                            timeFrame: timeFrame
                        )
                        RecordHistoryManager.shared.addRecord(recordType: recordType.rawValue, detail: detail)

                        // Track what was added
                        recordsByType[recordType.rawValue, default: []].append(timeFrame)
                    }
                }
            }

            // Save thumbnail if we have a photo
            if let image = selectedPhotoImage {
                // Use a consistent ID for the thumbnail
                let thumbnailId = UUID()
                ThumbnailCache.shared.saveThumbnail(from: image, for: thumbnailId)
            }

            // Check for new state/country
            if let regionInfo = RegionLookupService.shared.region(for: location) {
                // Check if this region is already visited
                let regionManager = RegionTrackingManager.shared
                let alreadyVisited: Bool
                if regionInfo.type == .state {
                    alreadyVisited = regionManager.visitedStates.contains { $0.regionCode == regionInfo.code }
                } else {
                    alreadyVisited = regionManager.visitedCountries.contains { $0.regionCode == regionInfo.code }
                }

                // Record the visit
                regionManager.recordVisit(
                    coordinate: location,
                    date: selectedDate,
                    source: .manual
                )

                // If it wasn't visited before, it's new
                if !alreadyVisited {
                    regionsAdded.append(regionInfo.name)
                }
            }

            // Reload regions to update maps
            await MainActor.run {
                RegionTrackingManager.shared.loadVisitedRegions()
            }

            // Build result message
            await MainActor.run {
                isAdding = false

                var lines: [String] = []

                // Format records by type with timeframes
                if !recordsByType.isEmpty {
                    let sortedTypes = recordsByType.keys.sorted()
                    for recordType in sortedTypes {
                        if let timeFrames = recordsByType[recordType] {
                            let timeFrameNames = timeFrames
                                .sorted { $0.sortOrder < $1.sortOrder }
                                .map { $0.rawValue }
                                .joined(separator: ", ")
                            lines.append("• \(recordType): \(timeFrameNames)")
                        }
                    }
                }

                if !regionsAdded.isEmpty {
                    lines.append("• New region: \(regionsAdded.joined(separator: ", "))")
                }

                if lines.isEmpty {
                    resultMessage = "Location added but didn't set any new records."
                } else {
                    resultMessage = lines.joined(separator: "\n")
                }

                showResultAlert = true
            }
        }
    }

    // MARK: - Helper Functions

    private func loadPhotoLocation() async {
        guard let item = selectedPhotoItem else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                await MainActor.run { showNoLocationAlert = true }
                return
            }

            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                await MainActor.run { showNoLocationAlert = true }
                return
            }

            guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                await MainActor.run { showNoLocationAlert = true }
                return
            }

            guard let gpsData = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any],
                  let latitude = gpsData[kCGImagePropertyGPSLatitude as String] as? Double,
                  let longitude = gpsData[kCGImagePropertyGPSLongitude as String] as? Double,
                  let latRef = gpsData[kCGImagePropertyGPSLatitudeRef as String] as? String,
                  let lonRef = gpsData[kCGImagePropertyGPSLongitudeRef as String] as? String else {
                await MainActor.run { showNoLocationAlert = true }
                return
            }

            let finalLatitude = latRef == "S" ? -latitude : latitude
            let finalLongitude = lonRef == "W" ? -longitude : longitude
            let coordinate = CLLocationCoordinate2D(latitude: finalLatitude, longitude: finalLongitude)

            // Extract altitude if available
            var photoAltitude: Double?
            if let gpsAltitude = gpsData[kCGImagePropertyGPSAltitude as String] as? Double {
                photoAltitude = gpsAltitude
            }

            // Extract timestamp
            var photoDate = Date()
            if let exifData = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let dateString = exifData[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                if let date = exifDateFormatter.date(from: dateString) {
                    photoDate = date
                }
            }

            let assetIdentifier = item.itemIdentifier
            var cloudIdentifier: String?
            if let localId = assetIdentifier {
                cloudIdentifier = PHPhotoLibrary.cloudIdentifier(forLocalIdentifier: localId)
            }

            let thumbnailImage = UIImage(data: data)

            await MainActor.run {
                locationName = nil
                selectedLocation = coordinate
                selectedDate = photoDate
                selectedPhotoAssetIdentifier = assetIdentifier
                selectedPhotoCloudIdentifier = cloudIdentifier
                selectedPhotoImage = thumbnailImage

                // Set altitude if available from photo
                if let alt = photoAltitude {
                    let displayAltitude = settings.unitSystem == .imperial ? alt * metersToFeet : alt
                    altitudeText = String(format: "%.0f", displayAltitude)
                }

                mapPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
                ))
            }
        } catch {
            await MainActor.run { showNoLocationAlert = true }
        }
    }

    private func geocodeLocation(_ coordinate: CLLocationCoordinate2D) {
        locationName = nil
        isGeocodingLocation = true

        if let cachedName = RecordHistoryManager.shared.lookupLocationName(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) {
            locationName = cachedName
            isGeocodingLocation = false
            return
        }

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

}
