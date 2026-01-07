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

    private func loadThumbnail() async {
        // First, try loading from thumbnail cache (fastest)
        if let cached = ThumbnailCache.shared.loadThumbnail(for: recordId) {
            loadedImage = cached
            return
        }

        // Fall back to Photos library with fallback: local ID → cloud ID → timestamp/location
        if let identifier = photoAssetIdentifier {
            if let photo = await PhotoReferenceManager.shared.fetchThumbnailWithFallback(
                identifier: identifier,
                cloudIdentifier: photoCloudIdentifier,
                timestamp: timestamp,
                coordinate: coordinate
            ) {
                loadedImage = photo
                return
            }
        }

        // Fallback to legacy embedded photo data
        if let data = photoData, let image = UIImage(data: data) {
            loadedImage = image
        }
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
                .background(FormatUtils.colorForRecordType(recordType).opacity(0.1))
                .cornerRadius(8)

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
