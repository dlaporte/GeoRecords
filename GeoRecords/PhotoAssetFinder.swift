import Foundation
import Photos
import CoreLocation

/// Shared utility for finding PHAssets using multiple fallback methods.
/// Used by both ThumbnailCache and PhotoReferenceManager to avoid code duplication.
///
/// TODO: Photo Access Centralization
/// Consider extracting photo access checks into a centralized PhotoAccessManager singleton to:
/// - Consolidate authorization status checks (currently in PhotoAssetFinder, PhotoLocationMonitor, ThumbnailCache, BackupManager)
/// - Provide a single place to request permissions
/// - Cache authorization status to avoid repeated system calls
/// - Handle authorization state changes via PHPhotoLibraryChangeObserver
/// This is a low-priority refactoring for maintainability, not a functional issue.
enum PhotoAssetFinder {

    /// Check if photo library access is authorized
    /// - Returns: true if authorized or limited access, false otherwise
    /// - Note: Consider centralizing via PhotoAccessManager in future refactoring
    private static var isPhotoAccessAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

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
        // Skip if photo access not authorized to avoid repeated errors
        guard isPhotoAccessAuthorized else {
            debugLog("📷 PhotoAssetFinder: Photo access not authorized")
            return nil
        }

        debugLog("📷 PhotoAssetFinder: Searching for photo - localId: \(localIdentifier ?? "nil"), cloudId: \(cloudIdentifier ?? "nil"), timestamp: \(timestamp?.description ?? "nil")")

        // First try direct local identifier lookup
        if let localId = localIdentifier {
            if let asset = findAssetByLocalIdentifier(localId) {
                debugLog("📷 PhotoAssetFinder: ✅ Found photo via local identifier")
                return asset
            } else {
                debugLog("📷 PhotoAssetFinder: ❌ Local identifier lookup failed")
            }
        }

        // Second: try cloud identifier (works across devices with same iCloud Photo Library)
        if let cloudId = cloudIdentifier {
            if let asset = findAssetByCloudIdentifier(cloudId) {
                debugLog("📷 PhotoAssetFinder: ✅ Found photo via cloud identifier")
                return asset
            } else {
                debugLog("📷 PhotoAssetFinder: ❌ Cloud identifier lookup failed")
            }
        }

        // Third fallback: search by timestamp and location
        if let timestamp = timestamp, let coordinate = coordinate {
            if let asset = findAssetByTimestampAndLocation(timestamp: timestamp, coordinate: coordinate) {
                debugLog("📷 PhotoAssetFinder: ✅ Found photo via timestamp/location fallback")
                return asset
            } else {
                debugLog("📷 PhotoAssetFinder: ❌ Timestamp/location fallback failed")
            }
        } else {
            debugLog("📷 PhotoAssetFinder: ⚠️ Cannot try fallback - missing timestamp or coordinate")
        }

        debugLog("📷 PhotoAssetFinder: ❌ All lookup methods exhausted - photo not found")
        return nil
    }

    /// Find asset by local identifier
    static func findAssetByLocalIdentifier(_ identifier: String) -> PHAsset? {
        // Skip if photo access not authorized to avoid repeated errors
        guard isPhotoAccessAuthorized else { return nil }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return fetchResult.firstObject
    }

    /// Find asset by cloud identifier (for cross-device access)
    static func findAssetByCloudIdentifier(_ cloudIdentifierString: String) -> PHAsset? {
        // Skip if photo access not authorized to avoid repeated errors
        guard isPhotoAccessAuthorized else { return nil }

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
        // Skip if photo access not authorized to avoid repeated errors
        guard isPhotoAccessAuthorized else { return nil }

        let options = PHFetchOptions()
        let startDate = timestamp.addingTimeInterval(-photoTimestampMatchThresholdSeconds)
        let endDate = timestamp.addingTimeInterval(photoTimestampMatchThresholdSeconds)
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            startDate as NSDate,
            endDate as NSDate
        )

        let fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        debugLog("📷 PhotoAssetFinder: Fallback search - found \(fetchResult.count) photos near timestamp \(timestamp)")

        var bestMatch: PHAsset?
        var candidatesChecked = 0
        var candidatesWithLocation = 0
        fetchResult.enumerateObjects { asset, _, stop in
            candidatesChecked += 1
            if let location = asset.location {
                candidatesWithLocation += 1
                let distance = location.distance(from: targetLocation)
                debugLog("📷 PhotoAssetFinder: Candidate \(candidatesChecked): distance = \(Int(distance))m (threshold: \(Int(photoLocationMatchThresholdMeters))m)")
                if distance < photoLocationMatchThresholdMeters {
                    debugLog("📷 PhotoAssetFinder: ✅ Match found within threshold!")
                    bestMatch = asset
                    stop.pointee = true
                }
            }
        }

        if bestMatch == nil {
            debugLog("📷 PhotoAssetFinder: Checked \(candidatesChecked) candidates, \(candidatesWithLocation) had GPS data, none within \(Int(photoLocationMatchThresholdMeters))m threshold")
        }

        return bestMatch
    }
}
