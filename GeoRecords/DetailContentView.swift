import SwiftUI
import CoreLocation
import MapKit

/// Shared content view for displaying record details
/// Used by both RecordDetailView and HistoryDetailView
struct DetailContentView: View {
    let record: RecordDetail
    let onSaveNotes: (String?) -> Void
    let onSaveLocationName: (String?) -> Void

    @EnvironmentObject var settings: SettingsManager

    @State private var isEditingNotes = false
    @State private var notesText: String = ""
    @State private var showFullScreenPhoto = false
    @State private var loadedPhoto: UIImage?
    @State private var photoNotAvailable = false
    @State private var isEditingLocationName = false
    @State private var locationNameText: String = ""
    @State private var displayedLocationName: String?
    @State private var showMapOptions = false

    // MARK: - Computed Properties

    private var recordIcon: String {
        FormatUtils.iconForRecordType(record.recordType)
    }

    private var iconColor: Color {
        guard let recordType = RecordType.from(string: record.recordType) else { return .gray }
        switch recordType {
        case .north, .south: return .blue
        case .east, .west: return .orange
        case .up: return .green
        case .fromHome: return .red
        }
    }

    private var timeFrameColor: Color {
        switch record.timeFrame {
        case .month: return .green
        case .year: return .orange
        case .allTime: return .blue
        }
    }

    private var timeFrameAbbrev: String {
        switch record.timeFrame {
        case .month: return "M"
        case .year: return "Y"
        case .allTime: return "A"
        }
    }

    private var timeFrameLabel: String {
        switch record.timeFrame {
        case .month: return "Monthly Record"
        case .year: return "Yearly Record"
        case .allTime: return "All-Time Record"
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: record.timestamp)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: record.timestamp)
    }

    private var formattedDateAdded: String? {
        guard let dateAdded = record.dateAdded else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: dateAdded)
    }

    private var formattedAltitude: String {
        if settings.unitSystem == .imperial {
            return String(format: "%.0f ft", record.altitude * metersToFeet)
        } else {
            return String(format: "%.0f m", record.altitude)
        }
    }

    private var formattedCoordinates: String {
        String(format: "%.4f, %.4f", record.coordinate.latitude, record.coordinate.longitude)
    }

    private var locationName: String {
        if let name = record.locationName, !name.isEmpty, name != unknownLocationString {
            return name
        }
        return formattedCoordinates
    }

    private var distanceFromHome: String? {
        FormatUtils.formatDistanceFromHome(
            from: record.coordinate,
            to: settings.homeCoordinate,
            unitSystem: settings.unitSystem
        )
    }

    private var mapPosition: MapCameraPosition {
        .region(MKCoordinateRegion(
            center: record.coordinate,
            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
        ))
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero Section
                heroSection

                // Photo or Map
                mediaSection

                // Details Card
                detailsCard

                // Location Card
                locationCard

                // Notes Card
                notesCard
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear {
            notesText = record.notes ?? ""
            locationNameText = record.locationName ?? ""
            displayedLocationName = record.locationName
        }
        .task {
            await loadPhoto()
            await prioritizeGeocoding()
        }
        .fullScreenCover(isPresented: $showFullScreenPhoto) {
            if let image = loadedPhoto {
                FullScreenPhotoView(image: image, isPresented: $showFullScreenPhoto)
            }
        }
    }

    // MARK: - Photo Loading

    /// Whether this record has a photo (either identifier or legacy data)
    private var hasPhoto: Bool {
        record.photoAssetIdentifier != nil || record.photoData != nil
    }

    private func loadPhoto() async {
        // Try to load from Photos library using identifier
        if let identifier = record.photoAssetIdentifier {
            if let photo = await PhotoReferenceManager.shared.fetchMediumPhoto(identifier: identifier) {
                loadedPhoto = photo
                return
            }
            // Photo not found in library
            photoNotAvailable = true
        }

        // Fallback to legacy embedded photo data
        if let data = record.photoData, let image = UIImage(data: data) {
            loadedPhoto = image
            return
        }
    }

    /// Prioritize geocoding for this record if it doesn't have a location name
    /// First checks local records for an existing name, then falls back to Apple geocoder
    private func prioritizeGeocoding() async {
        // Skip if already has a location name
        guard record.locationName == nil || record.locationName?.isEmpty == true else { return }

        let lat = record.coordinate.latitude
        let lon = record.coordinate.longitude

        // First, check if any existing record nearby has a location name
        if let existingName = await MainActor.run(body: {
            RecordHistoryManager.shared.lookupLocationName(latitude: lat, longitude: lon)
        }) {
            // Found existing name - use it and propagate to this record
            await MainActor.run {
                RecordHistoryManager.shared.updateLocationNameForCoordinates(
                    latitude: lat,
                    longitude: lon,
                    locationName: existingName
                )
                displayedLocationName = existingName
                locationNameText = existingName
            }
            debugLog("📍 Used existing location name: \(existingName)")
            return
        }

        // No existing name found - fall back to Apple geocoder
        let location = CLLocation(latitude: lat, longitude: lon)
        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let name = FormatUtils.formatPlacemarkName(placemark)

                // Update all records at this location
                await MainActor.run {
                    RecordHistoryManager.shared.updateLocationNameForCoordinates(
                        latitude: lat,
                        longitude: lon,
                        locationName: name
                    )
                    displayedLocationName = name
                    locationNameText = name
                }
                debugLog("📍 Geocoded from API: \(name)")
            }
        } catch {
            debugLog("📍 Geocoding failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 12) {
            // Icon and timeframe badge
            HStack(alignment: .top) {
                Image(systemName: recordIcon)
                    .font(.system(size: 44))
                    .foregroundColor(iconColor)

                Spacer()

                // Timeframe badge
                VStack(spacing: 4) {
                    Text(timeFrameAbbrev)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(timeFrameColor))

                    Text(timeFrameLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Value (large)
            VStack(spacing: 4) {
                Text(record.formattedValue(unitSystem: settings.unitSystem))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                // Location name with edit button
                Button(action: {
                    locationNameText = displayedLocationName ?? ""
                    isEditingLocationName = true
                }) {
                    HStack(spacing: 4) {
                        if let name = displayedLocationName, !name.isEmpty, name != unknownLocationString {
                            Text(name)
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("Add location name")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .sheet(isPresented: $isEditingLocationName) {
            LocationNameEditor(
                locationName: $locationNameText,
                onSave: {
                    let trimmedName = locationNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let newName = trimmedName.isEmpty ? nil : trimmedName
                    displayedLocationName = newName
                    onSaveLocationName(newName)
                    isEditingLocationName = false
                },
                onCancel: {
                    isEditingLocationName = false
                }
            )
            .presentationDetents([.height(200)])
        }
    }

    // MARK: - Media Section

    private var mediaSection: some View {
        Group {
            if let image = loadedPhoto {
                // Photo loaded successfully
                Button(action: { showFullScreenPhoto = true }) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 220)
                        .clipped()
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .overlay(
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .padding(8),
                            alignment: .topTrailing
                        )
                }
                .buttonStyle(.plain)
            } else if hasPhoto && !photoNotAvailable {
                // Photo is loading
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .frame(height: 220)
                    .overlay(
                        ProgressView()
                    )
            } else if photoNotAvailable {
                // Photo reference exists but photo not found in library
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .frame(height: 180)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("Photo not in library")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
            } else {
                // No photo - show map
                Map(position: .constant(mapPosition)) {
                    Marker(record.recordType, coordinate: record.coordinate)
                        .tint(iconColor)
                }
                .frame(height: 180)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Details Card

    private var detailsCard: some View {
        VStack(spacing: 0) {
            DetailRow(
                icon: "calendar",
                iconColor: .red,
                label: "Date",
                value: formattedDate
            )

            Divider().padding(.leading, 44)

            DetailRow(
                icon: "clock",
                iconColor: .orange,
                label: "Time",
                value: formattedTime
            )

            if shouldShowAltitude {
                Divider().padding(.leading, 44)

                DetailRow(
                    icon: "mountain.2",
                    iconColor: .green,
                    label: "Altitude",
                    value: formattedAltitude
                )
            }

            if let distance = distanceFromHome {
                Divider().padding(.leading, 44)

                DetailRow(
                    icon: "house",
                    iconColor: .purple,
                    label: "From Home",
                    value: distance
                )
            }

            if let dateAdded = formattedDateAdded {
                Divider().padding(.leading, 44)

                DetailRow(
                    icon: "plus.circle",
                    iconColor: .gray,
                    label: "Imported",
                    value: dateAdded
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }

    private var shouldShowAltitude: Bool {
        // Show altitude for elevation records or if altitude is significant
        let type = record.recordType.lowercased()
        return type.contains("up") || abs(record.altitude) > altitudeDisplayThreshold
    }

    // MARK: - Location Card

    private var locationCard: some View {
        VStack(spacing: 0) {
            DetailRow(
                icon: "mappin.circle",
                iconColor: .red,
                label: "Coordinates",
                value: formattedCoordinates
            )

            Divider().padding(.leading, 44)

            Button(action: openInMaps) {
                HStack(spacing: 12) {
                    Image(systemName: "map")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                        .frame(width: 28)

                    Text("Open in Maps")
                        .font(.subheadline)
                        .foregroundColor(.blue)

                    Spacer()

                    Image(systemName: "arrow.up.right.square")
                        .font(.subheadline)
                        .foregroundColor(.blue.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .confirmationDialog("Open in Maps", isPresented: $showMapOptions, titleVisibility: .visible) {
                Button("Apple Maps") {
                    openInAppleMaps()
                }

                if canOpenGoogleMaps {
                    Button("Google Maps") {
                        openInGoogleMaps()
                    }
                }

                if canOpenWaze {
                    Button("Waze") {
                        openInWaze()
                    }
                }

                Button("Cancel", role: .cancel) { }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Notes Card

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "note.text")
                    .font(.system(size: 18))
                    .foregroundColor(.yellow)
                    .frame(width: 28)

                Text("Notes")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if !isEditingNotes {
                    Button(record.notes == nil || record.notes?.isEmpty == true ? "Add" : "Edit") {
                        isEditingNotes = true
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if isEditingNotes {
                VStack(spacing: 12) {
                    TextEditor(text: $notesText)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(8)

                    HStack {
                        Button("Cancel") {
                            notesText = record.notes ?? ""
                            isEditingNotes = false
                        }
                        .foregroundColor(.secondary)

                        Spacer()

                        Button("Save") {
                            saveNotes()
                        }
                        .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            } else {
                if let notes = record.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                } else {
                    Text("No notes")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Map App Detection

    private var canOpenGoogleMaps: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private var canOpenWaze: Bool {
        guard let url = URL(string: "waze://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private var hasMultipleMapApps: Bool {
        canOpenGoogleMaps || canOpenWaze
    }

    // MARK: - Actions

    private func openInMaps() {
        if hasMultipleMapApps {
            showMapOptions = true
        } else {
            openInAppleMaps()
        }
    }

    private func openInAppleMaps() {
        let placemark = MKPlacemark(coordinate: record.coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = displayedLocationName ?? record.recordType
        mapItem.openInMaps(launchOptions: nil)
    }

    private func openInGoogleMaps() {
        let lat = record.coordinate.latitude
        let lon = record.coordinate.longitude
        if let url = URL(string: "comgooglemaps://?q=\(lat),\(lon)") {
            UIApplication.shared.open(url)
        }
    }

    private func openInWaze() {
        let lat = record.coordinate.latitude
        let lon = record.coordinate.longitude
        if let url = URL(string: "waze://?ll=\(lat),\(lon)&navigate=yes") {
            UIApplication.shared.open(url)
        }
    }

    private func saveNotes() {
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNotes = trimmedNotes.isEmpty ? nil : trimmedNotes
        onSaveNotes(finalNotes)
        isEditingNotes = false
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let icon: String
    let iconColor: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(iconColor)
                .frame(width: 28)

            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Full Screen Photo View

private struct FullScreenPhotoView: View {
    let image: UIImage
    @Binding var isPresented: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = lastScale * value
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale < 1.0 {
                                withAnimation { scale = 1.0 }
                                lastScale = 1.0
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1.0 {
                            scale = 1.0
                            lastScale = 1.0
                        } else {
                            scale = 2.0
                            lastScale = 2.0
                        }
                    }
                }
        }
        .overlay(
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(20),
            alignment: .topTrailing
        )
        .statusBar(hidden: true)
    }
}

// MARK: - Location Name Editor

private struct LocationNameEditor: View {
    @Binding var locationName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Location Name")
                .font(.headline)
                .padding(.top, 20)

            TextField("Location name", text: $locationName)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(UIColor.tertiarySystemFill))
                .foregroundColor(.primary)
                .cornerRadius(10)

                Button("Save") {
                    onSave()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue)
                .foregroundColor(.white)
                .fontWeight(.semibold)
                .cornerRadius(10)
            }
            .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            isFocused = true
        }
    }
}
