import Foundation
import Photos
import CoreLocation

/// Shared utility for finding PHAssets using multiple fallback methods.
/// Used by both ThumbnailCache and PhotoReferenceManager to avoid code duplication.
enum PhotoAssetFinder {

    /// Threshold for matching photos by location (in meters)
    private static let locationMatchThresholdMeters: Double = 100.0

    /// Threshold for matching photos by timestamp (in seconds)
    private static let timestampMatchThresholdSeconds: TimeInterval = 2.0

    /// Find a PHAsset using multiple fallback methods
    /// - Parameters:
    ///   - localIdentifier: The PHAsset.localIdentifier
    ///   - cloudIdentifier: The PHCloudIdentifier string for cross-device access
    ///   - timestamp: The photo's original timestamp (for fallback matching)
    ///   - coordinate: The photo's GPS coordinate (for fallback matching)
    /// - Returns: The PHAsset if found, nil otherwise
    static func findAsset(
        localIdentifier: String?,
        cloudIdentifier: String?,
        timestamp: Date?,
        coordinate: CLLocationCoordinate2D?
    ) -> PHAsset? {
        // First try direct local identifier lookup
        if let localId = localIdentifier,
           let asset = findAssetByLocalIdentifier(localId) {
            return asset
        }

        // Second: try cloud identifier (works across devices with same iCloud Photo Library)
        if let cloudId = cloudIdentifier,
           let asset = findAssetByCloudIdentifier(cloudId) {
            debugLog("📷 PhotoAssetFinder: Found photo via cloud identifier")
            return asset
        }

        // Third fallback: search by timestamp and location
        if let timestamp = timestamp, let coordinate = coordinate,
           let asset = findAssetByTimestampAndLocation(timestamp: timestamp, coordinate: coordinate) {
            debugLog("📷 PhotoAssetFinder: Found photo via timestamp/location fallback")
            return asset
        }

        return nil
    }

    /// Find asset by local identifier
    static func findAssetByLocalIdentifier(_ identifier: String) -> PHAsset? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return fetchResult.firstObject
    }

    /// Find asset by cloud identifier (for cross-device access)
    static func findAssetByCloudIdentifier(_ cloudIdentifierString: String) -> PHAsset? {
        let cloudIdentifier = PHCloudIdentifier(stringValue: cloudIdentifierString)
        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: [cloudIdentifier])

        guard let mapping = mappings[cloudIdentifier] else {
            return nil
        }

        switch mapping {
        case .success(let localIdentifier):
            return findAssetByLocalIdentifier(localIdentifier)
        case .failure:
            return nil
        }
    }

    /// Find asset by matching timestamp and GPS location
    static func findAssetByTimestampAndLocation(timestamp: Date, coordinate: CLLocationCoordinate2D) -> PHAsset? {
        let options = PHFetchOptions()
        let startDate = timestamp.addingTimeInterval(-timestampMatchThresholdSeconds)
        let endDate = timestamp.addingTimeInterval(timestampMatchThresholdSeconds)
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            startDate as NSDate,
            endDate as NSDate
        )

        let fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var bestMatch: PHAsset?
        fetchResult.enumerateObjects { asset, _, stop in
            if let location = asset.location {
                let distance = location.distance(from: targetLocation)
                if distance < locationMatchThresholdMeters {
                    bestMatch = asset
                    stop.pointee = true
                }
            }
        }

        return bestMatch
    }
}
