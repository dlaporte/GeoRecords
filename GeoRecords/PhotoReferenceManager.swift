import Foundation
import Photos
import UIKit

/// Manager for fetching photos from Apple Photos library using asset identifiers
/// Provides async interface for loading photos referenced by records
@MainActor
class PhotoReferenceManager {
    static let shared = PhotoReferenceManager()

    private init() {}

    /// Fetch a photo from the Photos library using its asset identifier
    /// - Parameters:
    ///   - identifier: The PHAsset.localIdentifier stored with the record
    ///   - targetSize: The desired size for the image (default: full size)
    ///   - contentMode: How to fit the image (default: aspectFit)
    /// - Returns: The UIImage if found, nil if photo no longer exists in library
    func fetchPhoto(
        identifier: String,
        targetSize: CGSize = PHImageManagerMaximumSize,
        contentMode: PHImageContentMode = .aspectFit
    ) async -> UIImage? {
        // Fetch the PHAsset using the identifier
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)

        guard let asset = fetchResult.firstObject else {
            debugLog("📷 Photo not found in library: \(identifier)")
            return nil
        }

        var hasResumed = false
        var degradedImage: UIImage?

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true  // Allow fetching from iCloud if needed
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                // Ensure we only resume once (callback may be called multiple times)
                guard !hasResumed else { return }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isFinal = (info?[PHImageResultIsDegradedKey] as? Bool) == false
                let hasError = info?[PHImageErrorKey] != nil
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false

                if isFinal || hasError || isCancelled {
                    // Final result - resume with whatever we have
                    hasResumed = true
                    continuation.resume(returning: image ?? degradedImage)
                } else if isDegraded && image != nil {
                    // Store degraded image as fallback
                    degradedImage = image
                }
            }
        }
    }

    /// Fetch a thumbnail-sized photo (optimized for list views)
    /// - Parameter identifier: The PHAsset.localIdentifier stored with the record
    /// - Returns: A thumbnail UIImage if found, nil if photo no longer exists
    func fetchThumbnail(identifier: String) async -> UIImage? {
        return await fetchPhoto(
            identifier: identifier,
            targetSize: CGSize(width: 200, height: 200),
            contentMode: .aspectFill
        )
    }

    /// Fetch a medium-sized photo (optimized for detail views)
    /// - Parameter identifier: The PHAsset.localIdentifier stored with the record
    /// - Returns: A medium-sized UIImage if found, nil if photo no longer exists
    func fetchMediumPhoto(identifier: String) async -> UIImage? {
        return await fetchPhoto(
            identifier: identifier,
            targetSize: CGSize(width: 800, height: 800),
            contentMode: .aspectFit
        )
    }

    /// Check if a photo exists in the library (without loading it)
    /// - Parameter identifier: The PHAsset.localIdentifier to check
    /// - Returns: true if the photo exists, false if deleted
    func photoExists(identifier: String) -> Bool {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return fetchResult.count > 0
    }
}

// MARK: - SwiftUI View Helper

import SwiftUI

/// A view that displays a photo from the Photos library using its asset identifier
/// Falls back to a placeholder if the photo is no longer available
struct PhotoReferenceView: View {
    let identifier: String?
    let legacyPhotoData: Data?  // Fallback for old records with embedded photos
    let targetSize: CGSize
    let contentMode: ContentMode
    let placeholder: AnyView

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var photoNotFound = false

    init(
        identifier: String?,
        legacyPhotoData: Data? = nil,
        targetSize: CGSize = CGSize(width: 400, height: 400),
        contentMode: ContentMode = .fit,
        placeholder: AnyView = AnyView(
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundColor(.secondary)
        )
    ) {
        self.identifier = identifier
        self.legacyPhotoData = legacyPhotoData
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isLoading {
                ProgressView()
            } else if photoNotFound {
                VStack(spacing: 8) {
                    placeholder
                    if identifier != nil {
                        Text("Photo not in library")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                placeholder
            }
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        // First, try to load from Photos library using identifier
        if let identifier = identifier {
            let phContentMode: PHImageContentMode = contentMode == .fill ? .aspectFill : .aspectFit
            if let photo = await PhotoReferenceManager.shared.fetchPhoto(
                identifier: identifier,
                targetSize: targetSize,
                contentMode: phContentMode
            ) {
                self.image = photo
                self.isLoading = false
                return
            }
            // Photo not found in library
            self.photoNotFound = true
        }

        // Fallback to legacy embedded photo data
        if let data = legacyPhotoData, let legacyImage = UIImage(data: data) {
            self.image = legacyImage
            self.isLoading = false
            return
        }

        // No photo available
        self.isLoading = false
    }
}

// MARK: - Convenience initializer for RecordDetail

extension PhotoReferenceView {
    /// Initialize from a RecordDetail, handling both new (identifier) and legacy (photoData) records
    init(record: RecordDetail, targetSize: CGSize = CGSize(width: 400, height: 400), contentMode: ContentMode = .fit) {
        self.init(
            identifier: record.photoAssetIdentifier,
            legacyPhotoData: record.photoData,
            targetSize: targetSize,
            contentMode: contentMode
        )
    }
}
