import SwiftUI
import Photos
import CoreLocation

/// View for confirming individual discovered records during photo import
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
        return FormatUtils.formatDiscoveredRecordValue(
            recordType: record.recordType,
            value: record.value,
            altitude: record.altitude,
            unitSystem: unitSystem,
            coordinatePrecision: 4
        )
    }

    private func formatCoordinate() -> String {
        let lat = record.coordinate.latitude
        let lon = record.coordinate.longitude
        return String(format: "%.4f, %.4f", lat, lon)
    }

    private func formatAltitude() -> String {
        if unitSystem == .imperial {
            let feet = record.altitude * metersToFeet
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
            if let cachedName = await sharedGeocodingCache.getCachedName(for: record.coordinate) {
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
                    let name = FormatUtils.formatPlacemarkName(placemark)

                    // Store in cache
                    Task {
                        await sharedGeocodingCache.setCachedName(name, for: record.coordinate)
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
