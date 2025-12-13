import SwiftUI
import Photos
import CoreLocation

// Global image cache that persists across record type changes
private var globalImageCache: [String: UIImage] = [:]  // Key: PHAsset localIdentifier

/// View for confirming individual discovered records during photo import
/// Shows a swipeable carousel of candidate photos for each record type
struct RecordConfirmationView: View {
    let candidates: [DiscoveredRecord]
    let timeFrameName: String
    let recordNumber: Int
    let totalRecords: Int
    let unitSystem: UnitSystem
    let scanner: PhotoLibraryScanner
    let onConfirm: (Int) -> Void
    let onSkip: () -> Void

    @State private var selectedIndex: Int = 0
    @State private var loadingAssets: Set<String> = []  // Track by localIdentifier
    @State private var locationNames: [String: String] = [:]  // Key: localIdentifier
    @State private var imageLoadTrigger = false  // Force view update when images load

    // Limit candidates to improve performance
    private var displayedCandidates: [DiscoveredRecord] {
        Array(candidates.prefix(50))
    }

    private var currentRecord: DiscoveredRecord? {
        guard selectedIndex >= 0, selectedIndex < displayedCandidates.count else { return nil }
        return displayedCandidates[selectedIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator with timeframe
            VStack(spacing: 8) {
                Text("Setting \(timeFrameName) Records")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("Record \(recordNumber) of \(totalRecords)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ProgressView(value: Double(recordNumber), total: Double(totalRecords))
                    .padding(.horizontal)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))

            if let record = currentRecord {
                ScrollView {
                    VStack(spacing: 16) {
                        // Record type header
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
                        .padding(.horizontal)
                        .padding(.top)

                        // Swipeable photo carousel with proper snapping
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 0) {
                                ForEach(Array(displayedCandidates.enumerated()), id: \.element.id) { index, candidate in
                                    PhotoCard(
                                        record: candidate,
                                        image: globalImageCache[candidate.photoAsset.localIdentifier],
                                        isLoading: loadingAssets.contains(candidate.photoAsset.localIdentifier)
                                    )
                                    .containerRelativeFrame(.horizontal)
                                    .id(index)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollPosition(id: Binding(
                            get: { selectedIndex },
                            set: { newValue in
                                if let newValue = newValue {
                                    selectedIndex = newValue
                                }
                            }
                        ))
                        .frame(height: 350)

                        // Photo counter with tap navigation
                        HStack {
                            Button(action: {
                                if selectedIndex > 0 {
                                    withAnimation { selectedIndex -= 1 }
                                }
                            }) {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(selectedIndex > 0 ? .blue : .gray.opacity(0.3))
                            }
                            .disabled(selectedIndex <= 0)

                            Text("\(selectedIndex + 1) of \(displayedCandidates.count)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(minWidth: 80)

                            Button(action: {
                                if selectedIndex < displayedCandidates.count - 1 {
                                    withAnimation { selectedIndex += 1 }
                                }
                            }) {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(selectedIndex < displayedCandidates.count - 1 ? .blue : .gray.opacity(0.3))
                            }
                            .disabled(selectedIndex >= displayedCandidates.count - 1)
                        }

                        // Record info card
                        RecordInfoCard(
                            record: record,
                            locationName: locationNames[record.photoAsset.localIdentifier],
                            unitSystem: unitSystem
                        )
                        .padding(.horizontal)

                        // Hint text
                        Text("Swipe to browse photos, then confirm or skip")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 8)
                    }
                }
            }

            // Action buttons
            HStack(spacing: 16) {
                Button(action: { onSkip() }) {
                    HStack {
                        Image(systemName: "forward.fill")
                        Text("Skip")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.15))
                    .foregroundColor(.secondary)
                    .cornerRadius(10)
                }

                Button(action: { onConfirm(selectedIndex) }) {
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
        .id(imageLoadTrigger)  // Force refresh when images load
        .onAppear {
            preloadImages()
            geocodeCurrentLocation()
        }
        .onChange(of: selectedIndex) { _, _ in
            preloadImages()
            geocodeCurrentLocation()
        }
        .onChange(of: candidates) { _, _ in
            // Reset index but DON'T clear image cache
            selectedIndex = 0
            preloadImages()
            geocodeCurrentLocation()
        }
    }

    // MARK: - Image Loading

    private func preloadImages() {
        // Preload current and next several images
        let indicesToLoad = (max(0, selectedIndex - 2)...min(displayedCandidates.count - 1, selectedIndex + 5))
            .filter { $0 >= 0 && $0 < displayedCandidates.count }

        for index in indicesToLoad {
            let candidate = displayedCandidates[index]
            let identifier = candidate.photoAsset.localIdentifier

            // Skip if already loaded or loading
            guard globalImageCache[identifier] == nil,
                  !loadingAssets.contains(identifier) else { continue }

            loadingAssets.insert(identifier)
            loadImage(for: candidate)
        }
    }

    private func loadImage(for record: DiscoveredRecord) {
        let identifier = record.photoAsset.localIdentifier
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic  // Fast initial load
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: record.photoAsset,
            targetSize: CGSize(width: 600, height: 600),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            DispatchQueue.main.async {
                if let image = image {
                    globalImageCache[identifier] = image
                    // Trigger view refresh
                    self.imageLoadTrigger.toggle()
                }
                // Only remove from loading if this is the final image (not degraded)
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    self.loadingAssets.remove(identifier)
                }
            }
        }
    }

    // MARK: - Geocoding

    private func geocodeCurrentLocation() {
        guard let record = currentRecord else { return }
        let identifier = record.photoAsset.localIdentifier

        // Skip if already geocoded
        guard locationNames[identifier] == nil else { return }

        Task {
            // Check cache first
            if let cachedName = await sharedGeocodingCache.getCachedName(for: record.coordinate) {
                await MainActor.run {
                    locationNames[identifier] = cachedName
                }
                return
            }

            // Geocode
            let location = CLLocation(latitude: record.coordinate.latitude, longitude: record.coordinate.longitude)
            let geocoder = CLGeocoder()

            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let placemark = placemarks.first {
                    let name = FormatUtils.formatPlacemarkName(placemark)
                    await sharedGeocodingCache.setCachedName(name, for: record.coordinate)
                    await MainActor.run {
                        locationNames[identifier] = name
                    }
                }
            } catch {
                debugLog("Geocoding error: \(error.localizedDescription)")
            }
        }
    }

    private func iconForRecordType(_ type: String) -> String {
        return FormatUtils.iconForRecordType(type)
    }
}

// Clear global cache (call when import completes)
func clearPhotoImportCache() {
    globalImageCache.removeAll()
}

// MARK: - Photo Card (for carousel)

private struct PhotoCard: View {
    let record: DiscoveredRecord
    let image: UIImage?
    let isLoading: Bool

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(12)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        }
                    }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Record Info Card

private struct RecordInfoCard: View {
    let record: DiscoveredRecord
    let locationName: String?
    let unitSystem: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Divider()

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
                }
                Text(formatCoordinate())
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

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
                Divider()
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
}
