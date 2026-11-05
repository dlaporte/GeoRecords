import SwiftUI
import CoreLocation
import MapKit
import PhotosUI

/// How a record's detail is hosted
enum DetailStyle: Equatable {
    /// A pushed page (iPhone, the Duo folded or upright, History's push): the photo
    /// or the map first, then the header row and the cards
    case page
    /// A split view's detail column (iPad, the Duo in landscape or book pose): the
    /// header row as the heading, the tab's overview map, then the panel
    case column
}

/// Shared content view for displaying record details
/// Used by RecordDetailView (pages and columns) and HistoryDetailView
struct DetailContentView: View {
    let record: RecordDetail
    let onSaveNotes: (String?) -> Void
    let onSaveLocationName: (String?) -> Void
    var onSavePhoto: ((PHAsset) -> Void)? = nil
    /// A pushed page, or a split view's detail column (with the tab's overview map)
    var style: DetailStyle = .page
    /// The overview map a column shows between its heading and the panel
    var map: AnyView? = nil

    @EnvironmentObject var settings: SettingsManager
    @State private var contentSize: CGSize = .zero
    @State private var headingHeight: CGFloat = 0

    @State private var isEditingNotes = false
    @State private var notesText: String = ""
    @State private var showFullScreenPhoto = false
    @State private var loadedPhoto: UIImage?
    @State private var photoNotAvailable = false
    @State private var isEditingLocationName = false
    @State private var locationNameText: String = ""
    @State private var displayedLocationName: String?
    @State private var showMapOptions = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var beatPreviousText: String?

    // MARK: - Computed Properties

    private var isRegionRecord: Bool {
        RecordType.from(string: record.recordType)?.isRegionVisit ?? false
    }

    private var recordIcon: String {
        FormatUtils.iconForRecordType(record.recordType)
    }

    private var iconColor: Color {
        FormatUtils.colorForRecordType(record.recordType)
    }

    private var timeFrameColor: Color {
        record.timeFrame.color
    }

    private var timeFrameAbbrev: String {
        record.timeFrame.abbreviation
    }

    private var formattedDate: String {
        fullWeekdayDateFormatter.string(from: record.timestamp)
    }

    private var formattedTime: String {
        time12Formatter.string(from: record.timestamp)
    }

    private var sourceDisplayName: String? {
        record.source?.displayName
    }

    /// "3 visits · last Aug 2026" for region records
    private var regionVisitsText: String? {
        guard isRegionRecord, let code = record.regionCode,
              let type = RecordType.from(string: record.recordType) else { return nil }
        let summary = RegionTrackingManager.shared.visitSummary(code: code, type: type)
        return VisitLog.text(count: summary.count, last: summary.last)
    }

    private var formattedAltitude: String {
        if settings.unitSystem == .imperial {
            return FormatUtils.formatFeet(record.altitude * metersToFeet)
        } else {
            return FormatUtils.formatMeters(record.altitude)
        }
    }

    private var formattedCoordinates: String {
        FormatUtils.formatCoordinatesWithCardinals(record.coordinate)
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
        content
            .background(Color(UIColor.systemGroupedBackground))
            .onAppear {
                notesText = record.notes ?? ""
                locationNameText = record.locationName ?? ""
                displayedLocationName = record.locationName
            }
            .task {
                beatPreviousText = RecordCaption.progressionDetail(
                    current: record,
                    previous: RecordHistoryManager.shared.previousRecord(before: record),
                    unitSystem: settings.unitSystem
                )
                await loadPhoto()
                await prioritizeGeocoding()
            }
            .fullScreenCover(isPresented: $showFullScreenPhoto) {
                if let image = loadedPhoto {
                    FullScreenPhotoView(image: image, isPresented: $showFullScreenPhoto)
                }
            }
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
            .onChange(of: selectedPhotoItem) { _, newItem in
                handlePhotoSelection(newItem)
            }
            .toolbar {
                // A page shares from its own bar; a column's host places share and
                // delete together (RecordDetailView)
                if style == .page, !isRegionRecord {
                    ToolbarItem(placement: .primaryAction) {
                        RecordShareLink(record: record)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .page:
            // The photo (or the map) first, then the facts; the tab behind holds the
            // overview map, so none follows the rows. The scroll view takes the room it
            // is offered whatever its content, so measuring it is safe
            ScrollView {
                VStack(spacing: 16) {
                    photoSlot(.fitWidth(maxHeight: contentSize.height * 0.55), orMap: true)
                    headerRow(.page)
                    detailsCard
                    locationCard
                    notesCard
                }
                .padding()
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        case .column:
            // A GeometryReader's size never depends on its children: dividing the
            // column from a measurement of the stack itself fed the stack's own
            // overflow back into the division and never settled
            GeometryReader { geometry in
                columnLayout(in: geometry.size)
            }
        }
    }

    // MARK: - A split view's detail column

    /// Heading, the overview map and the panel: the photo beside the cards where the
    /// column is wide enough, above them where it is not (DetailColumnStyle)
    private func columnLayout(in size: CGSize) -> some View {
        let columnStyle = DetailColumnStyle.style(forColumnWidth: size.width)
        let below = max(0, size.height - headingHeight - 3 * 16 - 8)
        let panelHeight = DetailColumnStyle.panelHeight(forColumnHeight: below, style: columnStyle)
        let mapHeight = max(0, below - panelHeight)
        return VStack(spacing: 16) {
            headerRow(.heading)
                .padding(.horizontal)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headingHeight = $0 }
            if let map {
                map
                    .frame(height: mapHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
            }
            Group {
                if columnStyle == .wide {
                    widePanel(width: size.width)
                } else {
                    stackedPanel
                }
            }
            .frame(height: panelHeight)
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func widePanel(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if showsPhotoSlot {
                photoSlot(.fitHeight(maxWidth: width * 0.56), orMap: false)
            }
            ScrollView {
                VStack(spacing: 16) {
                    detailsCard
                    locationCard
                    notesCard
                }
            }
        }
        .padding(.horizontal)
    }

    private var stackedPanel: some View {
        ScrollView {
            VStack(spacing: 16) {
                if showsPhotoSlot {
                    photoSlot(.fitWidth(maxHeight: nil), orMap: false)
                }
                detailsCard
                locationCard
                notesCard
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Header row

    private enum HeadingProminence {
        case page, heading
    }

    /// Icon, the value or region name, the place or first visit beneath, the timeframe
    /// badge trailing. As `.heading` it is the column's title, at large-title size
    private func headerRow(_ prominence: HeadingProminence) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: recordIcon)
                .font(.system(size: prominence == .heading ? 34 : 30))
                .foregroundColor(iconColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                // As the heading, the sidebar's large title exactly (34 pt bold), so the
                // two columns' titles share a baseline
                Text(isRegionRecord ? (displayedLocationName ?? record.recordType) : record.formattedValue(unitSystem: settings.unitSystem))
                    .font(prominence == .heading ? .largeTitle.bold() : .system(size: 30, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if isRegionRecord {
                    Text("First visited \(record.timestamp.formatted(.dateTime.month(.wide).day().year()))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Button(action: {
                        locationNameText = displayedLocationName ?? ""
                        isEditingLocationName = true
                    }) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if let name = displayedLocationName, !name.isEmpty, name != unknownLocationString {
                                PlaceNameText(name: name)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
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
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 4) {
                Text(timeFrameAbbrev)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(timeFrameColor))
                Text(record.timeFrame.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Photo slot

    /// Whether the panel reserves a photo slot: a photo exists, is loading, or is
    /// missing from the library (the slot then offers to pick one)
    private var showsPhotoSlot: Bool {
        loadedPhoto != nil || hasPhoto
    }

    /// The photo at its own aspect ratio, inside the content margins with the card
    /// radius; while it loads, or when it is missing from the library, a 4:3
    /// placeholder of the same width. With no photo at all a page shows the map
    /// instead, and a column shows nothing (its overview map is already there)
    @ViewBuilder
    private func photoSlot(_ fit: PhotoFit, orMap: Bool) -> some View {
        if let image = loadedPhoto {
            RecordPhotoView(image: image, fit: fit, canChange: onSavePhoto != nil,
                            selection: $selectedPhotoItem, showFullScreen: $showFullScreenPhoto)
        } else if hasPhoto && !photoNotAvailable {
            photoPlaceholder(fit) {
                ProgressView()
            }
        } else if photoNotAvailable {
            photoPlaceholder(fit) {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Photo not in library")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if onSavePhoto != nil {
                        // photoLibrary: .shared() is what makes itemIdentifier non-nil;
                        // without it handlePhotoSelection can never persist the choice
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                            Label("Select Photo", systemImage: "photo.badge.plus")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        } else if orMap {
            mapCard
        }
    }

    private func photoPlaceholder<Content: View>(_ fit: PhotoFit, @ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(UIColor.secondarySystemGroupedBackground))
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: fit.maxWidth, maxHeight: fit.maxHeight)
            .overlay(content())
    }

    /// The record's spot, where a page has no photo to show; carries the add-photo button
    private var mapCard: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: .constant(mapPosition)) {
                Marker(record.recordType, coordinate: record.coordinate)
                    .tint(iconColor)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .allowsHitTesting(false)

            if onSavePhoto != nil {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.badge.plus")
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
                .padding(8)
            }
        }
    }

    // MARK: - Photo Loading

    /// Whether this record has a photo (either identifier or legacy data)
    private var hasPhoto: Bool {
        record.photoAssetIdentifier != nil || record.photoData != nil
    }

    private func loadPhoto() async {
        debugLog("🖼️ DetailContentView.loadPhoto() called for '\(record.locationName ?? "Unknown")'")
        debugLog("🖼️ Photo identifiers - local: \(record.photoAssetIdentifier ?? "nil"), cloud: \(record.photoCloudIdentifier ?? "nil")")
        debugLog("🖼️ Timestamp: \(record.timestamp), Coordinate: \(record.coordinate.latitude), \(record.coordinate.longitude)")

        // Try to load from Photos library using identifier with fallback
        if let identifier = record.photoAssetIdentifier {
            // Use fallback method that tries: local ID → cloud ID → timestamp/location
            // This helps when restoring backups on different devices with same iCloud Photo Library
            debugLog("🖼️ Calling fetchMediumPhotoWithFallback...")
            if let photo = await PhotoReferenceManager.shared.fetchMediumPhotoWithFallback(
                identifier: identifier,
                cloudIdentifier: record.photoCloudIdentifier,
                timestamp: record.timestamp,
                coordinate: record.coordinate
            ) {
                debugLog("🖼️ ✅ Photo loaded successfully!")
                loadedPhoto = photo
                return
            }
            // Photo not found in library even with all fallback methods
            debugLog("🖼️ ❌ Photo not found in library - all methods exhausted")
            photoNotAvailable = true
        }

        // Fallback to legacy embedded photo data
        if let data = record.photoData, let image = UIImage(data: data) {
            debugLog("🖼️ Loading from legacy embedded photo data")
            loadedPhoto = image
            return
        }

        debugLog("🖼️ No photo loaded")
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

    /// Handle photo selection from picker
    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item = item else { return }

        Task {
            // Try to get asset identifier directly from PhotosPickerItem
            if let assetId = item.itemIdentifier {
                debugLog("📸 PhotosPicker selected item with identifier: \(assetId)")

                // The identifier from PhotosPicker should be the local identifier
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)

                if let asset = fetchResult.firstObject {
                    debugLog("📸 Found PHAsset for identifier")
                    loadAndSavePhoto(asset: asset)
                    return
                } else {
                    debugLog("📸 Could not find PHAsset for identifier, trying alternate method")
                }
            }

            // Fallback: Load the image data and try to match by loading
            // This handles cases where itemIdentifier doesn't work
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                debugLog("📸 Loaded image via data transfer")
                await MainActor.run {
                    self.loadedPhoto = image
                    self.photoNotAvailable = false
                }

                // Try to find the asset by fetching recent photos and matching
                // This is a fallback when we can't get the identifier directly
                if let assetId = item.itemIdentifier {
                    // Try fetching with the identifier one more time
                    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
                    if let asset = fetchResult.firstObject {
                        await MainActor.run {
                            self.onSavePhoto?(asset)
                        }
                    }
                }
            }
        }
    }

    /// Load image from PHAsset and save
    private func loadAndSavePhoto(asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        // Use requestImageDataAndOrientation for more reliable results
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 800, height: 600),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            if let image = image {
                Task { @MainActor in
                    self.loadedPhoto = image
                    self.photoNotAvailable = false
                    self.onSavePhoto?(asset)
                    debugLog("📸 Photo updated successfully")
                }
            }
        }
    }

    // MARK: - Details Card

    private var detailsCard: some View {
        VStack(spacing: 0) {
            DetailRow(icon: "calendar", iconColor: .red, label: "Date") {
                AdaptiveDateText(date: record.timestamp)
            }

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

            if let beatPreviousText {
                Divider().padding(.leading, 44)

                DetailRow(
                    icon: "arrow.up.right.circle",
                    iconColor: .green,
                    label: "Beat previous by",
                    value: beatPreviousText
                )
            }

            if let regionVisitsText {
                Divider().padding(.leading, 44)

                DetailRow(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: .teal,
                    label: "Visits",
                    value: regionVisitsText
                )
            }

            if let dateAdded = record.dateAdded {
                Divider().padding(.leading, 44)

                DetailRow(icon: "plus.circle", iconColor: .gray, label: "Added on") {
                    AdaptiveDateText(date: dateAdded)
                }
            }

            if let source = sourceDisplayName {
                Divider().padding(.leading, 44)

                DetailRow(
                    icon: "arrow.down.circle",
                    iconColor: .gray,
                    label: "Added by",
                    value: source
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

        // For region records, open zoomed out to show the region
        var launchOptions: [String: Any] = [:]

        if record.recordType == RecordType.state.rawValue {
            // States - zoom to show state-sized area
            launchOptions[MKLaunchOptionsMapSpanKey] = NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 10))
        } else if record.recordType == RecordType.country.rawValue {
            // Countries - zoom to show country-sized area
            launchOptions[MKLaunchOptionsMapSpanKey] = NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 15, longitudeDelta: 20))
        } else if record.recordType == RecordType.continent.rawValue {
            // Continents - zoom to show continent-sized area
            launchOptions[MKLaunchOptionsMapSpanKey] = NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 80))
        }

        mapItem.openInMaps(launchOptions: launchOptions.isEmpty ? nil : launchOptions)
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

private struct DetailRow<Value: View>: View {
    let icon: String
    let iconColor: Color
    let label: String
    @ViewBuilder let value: () -> Value

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

            value()
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

extension DetailRow where Value == Text {
    init(icon: String, iconColor: Color, label: String, value: String) {
        self.init(icon: icon, iconColor: iconColor, label: label) { Text(value) }
    }
}

/// The long date where it fits on one line, the abbreviated one where it would wrap
struct AdaptiveDateText: View {
    let date: Date

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(fullWeekdayDateFormatter.string(from: date))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(mediumDateFormatter.string(from: date))
                .lineLimit(1)
        }
    }
}

/// A place name on one line where it fits, else broken after its first comma
struct PlaceNameText: View {
    let name: String

    var body: some View {
        if let lines = PlaceName.lines(name) {
            ViewThatFits(in: .horizontal) {
                Text(name)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text(lines.first)
                    Text(lines.rest)
                }
            }
        } else {
            Text(name)
        }
    }
}

/// The record's share sheet item, placed by its host
struct RecordShareLink: View {
    let record: RecordDetail
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        ShareLink(
            item: RecordShareItem(record: record, unitSystem: settings.unitSystem,
                                  homeCoordinate: settings.homeCoordinate),
            preview: SharePreview("\(record.recordType) record", image: Image(systemName: FormatUtils.iconForRecordType(record.recordType)))
        ) {
            Image(systemName: "square.and.arrow.up")
        }
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
