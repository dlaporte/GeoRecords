//
//  SharedComponents.swift
//  GeoRecords
//
//  Shared UI components and helpers used across multiple views
//

import SwiftUI
import Photos
import CoreLocation

// MARK: - Card Sizing

/// Encapsulates responsive sizing values for record cards
/// Used by both RecordsView and MapsTabView for consistent card layouts
struct CardSizing {
    let isCompact: Bool

    init() {
        let screenHeight = UIScreen.main.bounds.height
        isCompact = screenHeight < compactScreenHeightThreshold
    }

    var cardSpacing: CGFloat { isCompact ? 8 : 12 }
    var iconSize: CGFloat { isCompact ? 32 : 44 }
    var valueFontSize: CGFloat { isCompact ? 24 : 36 }
    var photoSize: CGFloat { isCompact ? 80 : 120 }
    var cardPadding: CGFloat { isCompact ? 12 : 16 }
    var horizontalPadding: CGFloat { isCompact ? 20 : 26 }
    var contentSpacing: CGFloat { isCompact ? 6 : 12 }
}

// MARK: - Record Photo Thumbnail

/// Displays a photo thumbnail for a record, with multiple fallback loading strategies
/// Used by both RecordsView and MapsTabView
struct RecordPhotoThumbnail: View {
    let recordId: UUID
    let photoAssetIdentifier: String?
    let photoCloudIdentifier: String?
    let photoData: Data?  // Legacy fallback
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    let sizing: CardSizing

    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: sizing.photoSize, height: sizing.photoSize)
                    .clipShape(RoundedRectangle(cornerRadius: sizing.isCompact ? 8 : 12))
            } else {
                RoundedRectangle(cornerRadius: sizing.isCompact ? 8 : 12)
                    .fill(Color(UIColor.tertiarySystemGroupedBackground))
                    .frame(width: sizing.photoSize, height: sizing.photoSize)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.7)
                    )
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    /// The photo source the cached thumbnail must have been rendered from to be valid
    private var expectedThumbnailSource: String? {
        if let photoAssetIdentifier = photoAssetIdentifier { return photoAssetIdentifier }
        if photoData != nil { return ThumbnailCache.embeddedPhotoSource }
        return nil
    }

    private func loadThumbnail() async {
        let cache = ThumbnailCache.shared

        // Exact provenance match: the cached thumbnail was rendered from the record's
        // CURRENT photo — trust it. (Fallback-matched thumbnails must not stick forever;
        // that made cards show a different photo than the detail view.)
        if let cached = cache.loadValidatedThumbnail(for: recordId, expectedSource: expectedThumbnailSource) {
            loadedImage = cached
            return
        }

        // Provenance mismatch or missing (pre-update caches, fallback-matched assets):
        // show the stale thumbnail immediately — never blank a previously-working card —
        // then re-resolve at most once per session below.
        if let stale = cache.loadThumbnail(for: recordId) {
            loadedImage = stale
        }

        guard cache.shouldRevalidate(recordId) else { return }

        // Resolve via Photos: local ID → cloud ID → timestamp/location
        if let identifier = photoAssetIdentifier {
            if let result = await PhotoReferenceManager.shared.fetchThumbnailWithSource(
                identifier: identifier,
                cloudIdentifier: photoCloudIdentifier,
                timestamp: timestamp,
                coordinate: coordinate
            ) {
                loadedImage = result.image
                // Re-cache with provenance: pre-update caches heal to exact-match here;
                // fallback matches self-heal once the record's real asset is available
                cache.saveThumbnail(from: result.image, for: recordId, source: result.sourceIdentifier)
                return
            }
        }

        // Fallback to legacy embedded photo data
        if loadedImage == nil, let data = photoData, let image = UIImage(data: data) {
            loadedImage = image
            cache.saveThumbnail(from: image, for: recordId, source: ThumbnailCache.embeddedPhotoSource)
        }
        // Resolution failed: whatever stale thumbnail we showed above stays visible
    }
}

// MARK: - Record Card Header

/// Standard header component for record cards showing icon, type, and date
/// Used by RecordsView and potentially other card-based views
struct RecordCardHeader: View {
    let recordType: String
    let timestamp: Date
    let sizing: CardSizing

    var body: some View {
        HStack(spacing: sizing.isCompact ? 8 : 12) {
            Image(systemName: FormatUtils.iconForRecordType(recordType))
                .font(sizing.isCompact ? .title3 : .title)
                .foregroundColor(FormatUtils.colorForRecordType(recordType))
                .frame(width: sizing.iconSize, height: sizing.iconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(recordType)
                    .font(sizing.isCompact ? .caption : .headline)
                    .fontWeight(.semibold)
                Text(mediumDateFormatter.string(from: timestamp))
                    .font(sizing.isCompact ? .caption2 : .caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Empty Region State View

/// Generic empty state view for region tabs
/// Used by MapsTabView to show when no regions have been visited
struct EmptyRegionStateView: View {
    let regionPluralName: String
    let iconName: String

    /// Initialize with a RegionType
    init(regionType: RegionType) {
        self.regionPluralName = regionType.pluralName
        self.iconName = regionType == .state ? "map" : "globe"
    }

    /// Initialize for continents (which don't use RegionType enum)
    init(forContinents: Bool) {
        self.regionPluralName = "continents"
        self.iconName = "globe"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No \(regionPluralName.lowercased()) visited yet")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Visit new places to see them here")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
