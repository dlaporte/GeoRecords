import Foundation
import UIKit
import Photos
import CoreData

/// Manages cached thumbnails in the app group container for widget access and fast app loading
/// Thumbnails are stored as JPEG files named by record ID
@MainActor
class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let appGroupIdentifier = "group.com.georecords.shared"
    private let thumbnailDirectoryName = "Thumbnails"
    private let thumbnailSize = CGSize(width: 300, height: 300)
    private let compressionQuality: CGFloat = 0.7

    private var thumbnailDirectory: URL? {
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            debugLog("⚠️ ThumbnailCache: Could not access app group container")
            return nil
        }
        return appGroupURL.appendingPathComponent(thumbnailDirectoryName)
    }

    private init() {
        createThumbnailDirectoryIfNeeded()
    }

    // MARK: - Directory Management

    private func createThumbnailDirectoryIfNeeded() {
        guard let directory = thumbnailDirectory else { return }

        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                debugLog("📁 Created thumbnail cache directory")
            } catch {
                debugLog("❌ Failed to create thumbnail directory: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Save Thumbnails

    /// Save a thumbnail for a record from a UIImage
    /// - Parameters:
    ///   - image: The source image to create thumbnail from
    ///   - recordId: The record's UUID
    func saveThumbnail(from image: UIImage, for recordId: UUID) {
        guard let directory = thumbnailDirectory else { return }

        // Create thumbnail
        guard let thumbnail = createThumbnail(from: image) else {
            debugLog("⚠️ Failed to create thumbnail for record \(recordId)")
            return
        }

        // Save to file
        let fileURL = directory.appendingPathComponent("\(recordId.uuidString).jpg")
        guard let data = thumbnail.jpegData(compressionQuality: compressionQuality) else {
            debugLog("⚠️ Failed to create JPEG data for thumbnail")
            return
        }

        do {
            try data.write(to: fileURL)
            debugLog("💾 Saved thumbnail for record \(recordId)")
        } catch {
            debugLog("❌ Failed to save thumbnail: \(error.localizedDescription)")
        }
    }

    /// Save a thumbnail for a record from a PHAsset
    /// - Parameters:
    ///   - asset: The photo asset to create thumbnail from
    ///   - recordId: The record's UUID
    func saveThumbnail(from asset: PHAsset, for recordId: UUID) async {
        // Request thumbnail from Photos library
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let image = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: thumbnailSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    continuation.resume(returning: image)
                }
            }
        }

        if let image = image {
            saveThumbnail(from: image, for: recordId)
        }
    }

    /// Save a thumbnail for a record using its photo asset identifier
    /// - Parameters:
    ///   - assetIdentifier: The PHAsset.localIdentifier
    ///   - recordId: The record's UUID
    func saveThumbnail(fromAssetIdentifier assetIdentifier: String, for recordId: UUID) async {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            debugLog("⚠️ Could not find asset for identifier: \(assetIdentifier)")
            return
        }

        await saveThumbnail(from: asset, for: recordId)
    }

    // MARK: - Load Thumbnails

    /// Load a cached thumbnail for a record
    /// - Parameter recordId: The record's UUID
    /// - Returns: The cached thumbnail image, or nil if not found
    func loadThumbnail(for recordId: UUID) -> UIImage? {
        guard let directory = thumbnailDirectory else { return nil }

        let fileURL = directory.appendingPathComponent("\(recordId.uuidString).jpg")

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }

        return image
    }

    /// Check if a thumbnail exists for a record
    /// - Parameter recordId: The record's UUID
    /// - Returns: true if thumbnail exists
    func thumbnailExists(for recordId: UUID) -> Bool {
        guard let directory = thumbnailDirectory else { return false }
        let fileURL = directory.appendingPathComponent("\(recordId.uuidString).jpg")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Delete Thumbnails

    /// Delete a cached thumbnail
    /// - Parameter recordId: The record's UUID
    func deleteThumbnail(for recordId: UUID) {
        guard let directory = thumbnailDirectory else { return }

        let fileURL = directory.appendingPathComponent("\(recordId.uuidString).jpg")

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                debugLog("🗑️ Deleted thumbnail for record \(recordId)")
            }
        } catch {
            debugLog("❌ Failed to delete thumbnail: \(error.localizedDescription)")
        }
    }

    /// Clear all cached thumbnails
    func clearAllThumbnails() {
        guard let directory = thumbnailDirectory else { return }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            debugLog("🗑️ Cleared all cached thumbnails")
        } catch {
            debugLog("❌ Failed to clear thumbnails: \(error.localizedDescription)")
        }
    }

    // MARK: - Thumbnail Generation

    private func createThumbnail(from image: UIImage) -> UIImage? {
        let size = thumbnailSize
        let aspectRatio = image.size.width / image.size.height

        var targetSize: CGSize
        if aspectRatio > 1 {
            // Landscape - fit to height
            targetSize = CGSize(width: size.height * aspectRatio, height: size.height)
        } else {
            // Portrait - fit to width
            targetSize = CGSize(width: size.width, height: size.width / aspectRatio)
        }

        // Create thumbnail
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let thumbnail = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return thumbnail
    }

    // MARK: - Migration

    /// Generate thumbnails for all existing records that have photos but no cached thumbnail
    /// Call this on app launch or when migrating
    func generateMissingThumbnails() async {
        let context = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<RecordHistoryEntry>(entityName: "RecordHistoryEntry")

        do {
            let entries = try context.fetch(request)
            var generatedCount = 0

            for entry in entries {
                guard let recordId = entry.id else { continue }

                // Skip if thumbnail already exists
                if thumbnailExists(for: recordId) { continue }

                // Try to generate from asset identifier
                if let assetIdentifier = entry.photoAssetIdentifier {
                    await saveThumbnail(fromAssetIdentifier: assetIdentifier, for: recordId)
                    generatedCount += 1
                }
                // Or from legacy photo data
                else if let photoData = entry.photoData, let image = UIImage(data: photoData) {
                    saveThumbnail(from: image, for: recordId)
                    generatedCount += 1
                }
            }

            if generatedCount > 0 {
                debugLog("📸 Generated \(generatedCount) missing thumbnails")
            }
        } catch {
            debugLog("❌ Failed to generate missing thumbnails: \(error.localizedDescription)")
        }
    }
}
