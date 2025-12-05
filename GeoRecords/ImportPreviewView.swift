import SwiftUI
import Photos
import CoreLocation

struct ImportPreviewView: View {
    @EnvironmentObject var scanner: PhotoLibraryScanner
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.dismiss) var dismiss
    @State private var isImporting = false
    @State private var showSuccess = false
    @State private var importedCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if scanner.isScanning {
                    // Scanning progress
                    VStack(spacing: 20) {
                        ProgressView(value: scanner.progress) {
                            Text("Scanning Photo Library...")
                                .font(.headline)
                        }
                        .padding()

                        VStack(spacing: 8) {
                            Text("Scanned \(scanner.scannedPhotos) of \(scanner.totalPhotos) photos")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Text("\(scanner.photosWithLocation) photos with location data")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                } else if let errorMessage = scanner.errorMessage {
                    // Error state
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)

                        Text(errorMessage)
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        Button("Close") {
                            dismiss()
                        }
                        .padding()
                    }
                    .padding()
                } else if scanner.discoveredRecords.isEmpty {
                    // No records found
                    VStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)

                        Text("No Records Found")
                            .font(.headline)

                        Text("We couldn't find any photos with location data that would set new records.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Close") {
                            dismiss()
                        }
                        .padding()
                    }
                    .padding()
                } else if scanner.isConfirming {
                    // Confirmation flow - show one record at a time per timeframe
                    if let currentRecord = scanner.currentRecord {
                        let progress = scanner.currentProgress
                        RecordConfirmationView(
                            record: currentRecord,
                            timeFrameName: scanner.currentTimeFrameName,
                            recordNumber: progress.current,
                            totalRecords: progress.total,
                            unitSystem: settings.unitSystem,
                            scanner: scanner,
                            onConfirm: {
                                scanner.confirmCurrentRecord()
                            },
                            onReject: {
                                scanner.rejectCurrentRecord()
                            }
                        )
                    }
                } else {
                    // Confirmation complete - show summary and import button
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                            .padding(.top, 40)

                        Text("Confirmation Complete!")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("You've selected \(scanner.confirmedRecords.count) record(s) to import")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Spacer()

                        // Import button
                        Button(action: {
                            importRecords()
                        }) {
                            HStack {
                                if isImporting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Text("Import \(scanner.confirmedRecords.count) Record(s)")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(isImporting || scanner.confirmedRecords.isEmpty)
                        .padding()
                    }
                }
            }
            .navigationTitle("Import from Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Success!", isPresented: $showSuccess) {
                Button("View Records") {
                    dismiss()
                }
            } message: {
                Text("Imported \(importedCount) records from your photo library!")
            }
        }
    }

    private func importRecords() {
        isImporting = true

        Task {
            await scanner.importSelectedRecords { count in
                importedCount = count
                isImporting = false
                showSuccess = true
                // Suppression is now handled inside importSelectedRecords() after all records are imported
            }
        }
    }
}

struct DiscoveredRecordRow: View {
    @Binding var record: DiscoveredRecord
    let unitSystem: UnitSystem
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button(action: {
                record.selected.toggle()
            }) {
                Image(systemName: record.selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(record.selected ? .blue : .gray)
                    .font(.title2)
            }
            .buttonStyle(PlainButtonStyle())

            // Thumbnail
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .overlay {
                        ProgressView()
                    }
            }

            // Record info
            VStack(alignment: .leading, spacing: 4) {
                Text(record.recordType)
                    .font(.headline)

                Text(formatValue())
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(formatDate(record.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .onAppear {
            loadThumbnail()
        }
    }

    private func formatValue() -> String {
        if record.recordType.contains("North") || record.recordType.contains("South") ||
           record.recordType.contains("East") || record.recordType.contains("West") {
            return String(format: "%.2f°", record.value)
        } else if record.recordType.contains("Up") || record.recordType.contains("Down") {
            if unitSystem == .imperial {
                let feet = record.altitude * 3.28084
                return String(format: "%.0f ft", feet)
            } else {
                return String(format: "%.0f m", record.altitude)
            }
        } else if record.recordType == "Furthest from Home" {
            if unitSystem == .imperial {
                let miles = record.value / 5280.0
                return String(format: "%.2f mi", miles)
            } else {
                let meters = record.value * 0.3048
                let km = meters / 1000.0
                return String(format: "%.2f km", km)
            }
        }
        return String(format: "%.2f", record.value)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: record.photoAsset,
            targetSize: CGSize(width: 120, height: 120),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            self.thumbnail = image
        }
    }
}

// MARK: - Geocoding Cache
private actor GeocodingCache {
    private var cache: [String: String] = [:]

    func getCachedLocation(latitude: Double, longitude: Double) -> String? {
        let key = cacheKey(latitude: latitude, longitude: longitude)
        return cache[key]
    }

    func setCachedLocation(latitude: Double, longitude: Double, name: String) {
        let key = cacheKey(latitude: latitude, longitude: longitude)
        cache[key] = name
    }

    private func cacheKey(latitude: Double, longitude: Double) -> String {
        // Round to 4 decimal places (~11 meters precision)
        let roundedLat = round(latitude * 10000) / 10000
        let roundedLon = round(longitude * 10000) / 10000
        return "\(roundedLat),\(roundedLon)"
    }
}

// Global cache instance
private let geocodingCache = GeocodingCache()

// MARK: - Record Confirmation View
struct RecordConfirmationView: View {
    let record: DiscoveredRecord
    let timeFrameName: String
    let recordNumber: Int
    let totalRecords: Int
    let unitSystem: UnitSystem
    let scanner: PhotoLibraryScanner
    let onConfirm: () -> Void
    let onReject: () -> Void

    @State private var fullSizeImage: UIImage?
    @State private var isLoadingImage = true
    @State private var locationName: String?
    @State private var currentRecordId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator with timeframe
            VStack(spacing: 8) {
                Text("Setting \(timeFrameName) Records")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("Confirming \(recordNumber) of \(totalRecords)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ProgressView(value: Double(recordNumber), total: Double(totalRecords))
                    .padding(.horizontal)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))

            ScrollView {
                VStack(spacing: 20) {
                    // Photo
                    if let image = fullSizeImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 400)
                            .cornerRadius(12)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 300)
                            .cornerRadius(12)
                            .overlay {
                                if isLoadingImage {
                                    ProgressView()
                                }
                            }
                    }

                    // Record info card
                    VStack(alignment: .leading, spacing: 16) {
                        // Record type
                        HStack {
                            Image(systemName: iconForRecordType(record.recordType))
                                .font(.title2)
                                .foregroundColor(.blue)
                            Text(record.recordType)
                                .font(.title3)
                                .fontWeight(.bold)
                            Spacer()
                            Text(timeFrameName)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                        }

                        Divider()

                        // Value
                        HStack {
                            Text("Value:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatValue())
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }

                        // Location
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Location:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            if let locationName = locationName {
                                Text(locationName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .multilineTextAlignment(.trailing)
                            }
                            Text(formatCoordinate())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }

                        // Date
                        HStack {
                            Text("Date:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatDate(record.timestamp))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }

                        // Altitude (if relevant)
                        if record.recordType.contains("Up") || record.recordType.contains("Down") {
                            HStack {
                                Text("Altitude:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(formatAltitude())
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )

                    // Question
                    Text("Does this location look accurate?")
                        .font(.headline)
                        .padding(.top)

                    Text("Confirm only if the GPS data appears correct.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            }

            // Action buttons
            HStack(spacing: 16) {
                Button(action: onReject) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Skip")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(10)
                }

                Button(action: onConfirm) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Confirm")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
            .padding()
            .background(Color(UIColor.systemBackground))
        }
        .onAppear {
            loadFullSizeImage()
            geocodeLocation()
        }
        .onChange(of: record.id) { _, newId in
            // Reset and reload when record changes
            isLoadingImage = true
            fullSizeImage = nil
            locationName = nil
            currentRecordId = newId
            loadFullSizeImage()
            geocodeLocation()
        }
        .id(record.id) // Force view refresh when record changes
    }

    private func loadFullSizeImage() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        PHImageManager.default().requestImage(
            for: record.photoAsset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            self.fullSizeImage = image
            self.isLoadingImage = false
        }
    }

    private func formatValue() -> String {
        if record.recordType.contains("North") || record.recordType.contains("South") ||
           record.recordType.contains("East") || record.recordType.contains("West") {
            return String(format: "%.4f°", record.value)
        } else if record.recordType.contains("Up") || record.recordType.contains("Down") {
            if unitSystem == .imperial {
                let feet = record.altitude * 3.28084
                return String(format: "%.0f ft", feet)
            } else {
                return String(format: "%.0f m", record.altitude)
            }
        } else if record.recordType == "Furthest from Home" {
            if unitSystem == .imperial {
                let miles = record.value / 5280.0
                return String(format: "%.2f mi", miles)
            } else {
                let meters = record.value * 0.3048
                let km = meters / 1000.0
                return String(format: "%.2f km", km)
            }
        }
        return String(format: "%.2f", record.value)
    }

    private func formatCoordinate() -> String {
        let lat = record.coordinate.latitude
        let lon = record.coordinate.longitude
        return String(format: "%.4f, %.4f", lat, lon)
    }

    private func formatAltitude() -> String {
        if unitSystem == .imperial {
            let feet = record.altitude * 3.28084
            return String(format: "%.0f ft", feet)
        } else {
            return String(format: "%.0f m", record.altitude)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func geocodeLocation() {
        let lat = record.coordinate.latitude
        let lon = record.coordinate.longitude

        // Capture the record ID at the time of the request
        let requestRecordId = record.id
        currentRecordId = requestRecordId

        // Check cache first
        Task {
            if let cachedName = await geocodingCache.getCachedLocation(latitude: lat, longitude: lon) {
                debugLog("📍 Using cached location for (\(lat), \(lon)): \(cachedName)")

                // Only update if this result is still relevant
                if self.currentRecordId == requestRecordId {
                    await MainActor.run {
                        self.locationName = cachedName
                    }

                    // Update the record in the scanner
                    await MainActor.run {
                        self.scanner.updateLocationName(for: requestRecordId, locationName: cachedName)
                    }
                }
                return
            }

            // Not in cache, perform geocoding
            debugLog("🌐 Geocoding location (\(lat), \(lon))")
            let location = CLLocation(latitude: lat, longitude: lon)
            let geocoder = CLGeocoder()

            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let error = error {
                    debugLog("Geocoding error: \(error.localizedDescription)")
                    return
                }

                if let placemark = placemarks?.first {
                    var components: [String] = []

                    if let locality = placemark.locality {
                        components.append(locality)
                    }
                    if let administrativeArea = placemark.administrativeArea {
                        components.append(administrativeArea)
                    }
                    if let country = placemark.country {
                        components.append(country)
                    }

                    let name = components.joined(separator: ", ")

                    // Store in cache
                    Task {
                        await geocodingCache.setCachedLocation(latitude: lat, longitude: lon, name: name)
                        debugLog("💾 Cached location for (\(lat), \(lon)): \(name)")
                    }

                    // Only update if this result is still relevant (user hasn't moved to another record)
                    if self.currentRecordId == requestRecordId {
                        self.locationName = name

                        // Update the record in the scanner
                        Task { @MainActor in
                            self.scanner.updateLocationName(for: requestRecordId, locationName: name)
                        }
                    } else {
                        debugLog("Discarding stale geocoding result for record \(requestRecordId)")
                    }
                }
            }
        }
    }

    private func iconForRecordType(_ type: String) -> String {
        return FormatUtils.iconForRecordType(type)
    }
}
