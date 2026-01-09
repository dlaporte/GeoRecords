import Foundation
import Photos
import CoreLocation

/// PhotoLocationMonitor: Monitors the photo library for new photos and checks their locations for records
///
/// **Purpose:**
/// When a user takes a photo, this monitor checks if the photo's geolocation would set a new record.
/// This catches extreme locations that background location tracking might miss (since it only triggers
/// every ~500 meters).
///
/// **Duplicate Handling:**
/// If a new photo's location is within threshold of a record created in the last 5 minutes,
/// the existing record is replaced with the photo-based one (so the photo gets attached).
/// This handles the case where:
/// 1. Background location tracking fires and creates a record (without photo)
/// 2. User takes a photo moments later at the same spot
/// 3. The photo-based record replaces the photo-less one
///
/// **Integration:**
/// - Register in GeoRecordsApp.init() via `PhotoLocationMonitor.shared.startMonitoring()`
/// - Uses existing `RecordManager.updateRecords()` logic for threshold checking
/// - Automatically attaches the photo to any new records created
@MainActor
class PhotoLocationMonitor: NSObject, ObservableObject {
    static let shared = PhotoLocationMonitor()

    /// Time window for considering a record as a "recent duplicate" (in seconds)
    /// Records created within this window can be replaced by photo-based records
    private let recentRecordWindowSeconds: TimeInterval = photoProcessingWindowSeconds

    /// Track whether we're currently monitoring
    @Published private(set) var isMonitoring = false

    /// Track the last processed photo to avoid duplicates
    private var lastProcessedAssetIdentifier: String?

    private override init() {
        super.init()
    }

    /// Start monitoring the photo library for new photos
    /// Call this from app initialization
    func startMonitoring() {
        guard !isMonitoring else {
            debugLog("📸 PhotoLocationMonitor: Already monitoring")
            return
        }

        // Check photo library authorization
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            debugLog("📸 PhotoLocationMonitor: Photo library access not authorized (status: \(status.rawValue))")
            return
        }

        PHPhotoLibrary.shared().register(self)
        isMonitoring = true
        debugLog("📸 PhotoLocationMonitor: Started monitoring for new photos")
    }

    /// Stop monitoring the photo library
    func stopMonitoring() {
        guard isMonitoring else { return }

        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isMonitoring = false
        debugLog("📸 PhotoLocationMonitor: Stopped monitoring")
    }

    /// Process a new photo asset to check for records
    private func processNewPhoto(_ asset: PHAsset) {
        // Skip if no location data
        guard let location = asset.location else {
            debugLog("📸 New photo has no location data, skipping")
            return
        }

        // Skip if this is the same asset we just processed (prevents duplicate processing)
        if asset.localIdentifier == lastProcessedAssetIdentifier {
            debugLog("📸 Skipping duplicate asset: \(asset.localIdentifier)")
            return
        }
        lastProcessedAssetIdentifier = asset.localIdentifier

        // Validate the location
        switch validateLocation(location) {
        case .nullIsland:
            debugLog("📸 Photo location is Null Island, skipping")
            return
        case .unrealisticAltitude(let meters):
            debugLog("📸 Photo has unrealistic altitude (\(Int(meters))m), skipping")
            return
        case .valid:
            break
        }

        // Skip photos at home
        if let homeCoord = SettingsManager.shared.homeCoordinate {
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let distanceFromHome = location.distance(from: homeLocation)
            if distanceFromHome <= atHomeRadiusMeters {
                debugLog("📸 Photo is at home (within \(Int(distanceFromHome))m), skipping")
                return
            }
        }

        debugLog("📸 Processing new photo at: \(location.coordinate.latitude), \(location.coordinate.longitude)")

        // Check each record type to see if this photo would set a new record
        // or should replace a recent record
        Task {
            await checkPhotoForRecords(asset: asset, location: location)
        }
    }

    /// Check if a photo's location would create or replace any records
    private func checkPhotoForRecords(asset: PHAsset, location: CLLocation) async {
        let settings = SettingsManager.shared
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let alt = location.altitude

        // Calculate distance from home if available
        var distanceFromHome: Double?
        if let homeCoord = settings.homeCoordinate {
            distanceFromHome = distanceBetween(from: location.coordinate, to: homeCoord)
        }

        // Get thresholds
        let latThreshold = settings.minLatitudeDelta
        let lonThreshold = settings.minLongitudeDelta
        let altThreshold = settings.minAltitudeDeltaMeters
        let distanceThreshold = settings.minDistanceDeltaMeters

        // Get photo's cloud identifier for cross-device sync
        let cloudId = PHPhotoLibrary.cloudIdentifier(for: asset)

        // Reverse geocode the location
        let locationName = await geocodeLocation(location)

        // Track if we created any records
        var recordsCreated: [String] = []

        // Define checks for each record type
        let recordChecks: [(type: RecordType, value: Double, threshold: Double)] = [
            (.north, lat, latThreshold),
            (.south, lat, latThreshold),
            (.east, lon, lonThreshold),
            (.west, lon, lonThreshold),
            (.up, alt, altThreshold)
        ]

        // Add distance from home if available
        var allChecks = recordChecks
        if let distance = distanceFromHome {
            allChecks.append((.fromHome, distance, distanceThreshold))
        }

        // Check each record type across all timeframes
        for check in allChecks {
            for timeFrame in TimeFrame.userVisibleCases {
                let result = await checkAndCreateRecord(
                    recordType: check.type,
                    value: check.value,
                    threshold: check.threshold,
                    location: location,
                    locationName: locationName,
                    timeFrame: timeFrame,
                    asset: asset,
                    cloudId: cloudId
                )

                if result {
                    recordsCreated.append("\(check.type.rawValue) (\(timeFrame.rawValue))")
                }
            }
        }

        if !recordsCreated.isEmpty {
            debugLog("📸 Photo created records: \(recordsCreated.joined(separator: ", "))")
        }
    }

    /// Check if a photo should create or replace a record
    /// Returns true if a record was created or replaced
    private func checkAndCreateRecord(
        recordType: RecordType,
        value: Double,
        threshold: Double,
        location: CLLocation,
        locationName: String?,
        timeFrame: TimeFrame,
        asset: PHAsset,
        cloudId: String?
    ) async -> Bool {
        let recordManager = RecordManager.shared
        let historyManager = RecordHistoryManager.shared
        let settings = SettingsManager.shared

        let currentRecord = recordManager.getRecord(type: recordType.rawValue, timeFrame: timeFrame)
        let now = Date()

        // Calculate if this value would be a new record
        let isNewRecord: Bool
        if let current = currentRecord {
            let delta: Double
            switch recordType {
            case .south, .west:
                // Lower is better
                delta = current.value - value
            default:
                // Higher is better
                delta = value - current.value
            }
            isNewRecord = delta > threshold
        } else {
            // No existing record, this would be the first
            isNewRecord = true
        }

        // Check if there's a recent record we should replace (even if not a "new" record by threshold)
        let shouldReplaceRecent: Bool
        if !isNewRecord, let current = currentRecord {
            // Check if the current record was created recently and doesn't have a photo
            let timeSinceRecord = now.timeIntervalSince(current.timestamp)
            let isRecent = timeSinceRecord <= recentRecordWindowSeconds
            let hasNoPhoto = current.photoAssetIdentifier == nil && current.photoData == nil

            // Also verify this photo's value is within threshold of the recent record
            // (i.e., it's essentially the same location)
            let deltaFromRecent: Double
            switch recordType {
            case .south, .west:
                deltaFromRecent = abs(current.value - value)
            default:
                deltaFromRecent = abs(value - current.value)
            }
            let isWithinThreshold = deltaFromRecent <= threshold

            shouldReplaceRecent = isRecent && hasNoPhoto && isWithinThreshold

            if shouldReplaceRecent {
                debugLog("📸 Found recent photo-less record to replace: \(recordType.rawValue) (\(timeFrame.rawValue)) created \(Int(timeSinceRecord))s ago")
            }
        } else {
            shouldReplaceRecent = false
        }

        // If neither a new record nor replacing a recent one, skip
        guard isNewRecord || shouldReplaceRecent else {
            return false
        }

        // Create the new record detail with photo attached
        let newRecord = RecordDetail(
            value: value,
            timestamp: asset.creationDate ?? now,
            coordinate: location.coordinate,
            altitude: location.altitude,
            locationName: locationName,
            recordType: recordType.rawValue,
            timeFrame: timeFrame,
            photoAssetIdentifier: asset.localIdentifier,
            photoCloudIdentifier: cloudId,
            source: .photo
        )

        if shouldReplaceRecent, let oldRecord = currentRecord {
            // Delete the old record and create the new one with photo
            historyManager.deleteRecord(recordId: oldRecord.id)
            debugLog("📸 Deleted old photo-less record: \(oldRecord.id)")
        }

        // Save the new record with photo
        let saveSucceeded = historyManager.addRecord(recordType: recordType.rawValue, detail: newRecord)

        if saveSucceeded {
            // Update in-memory record
            recordManager.setRecord(type: recordType.rawValue, timeFrame: timeFrame, record: newRecord)

            // Increment badge for this timeframe
            recordManager.incrementBadge(for: timeFrame)

            // Send notification based on settings
            let shouldNotify: Bool
            switch timeFrame {
            case .daily:
                shouldNotify = false
            case .month:
                shouldNotify = settings.notifyOnMonthlyRecords
            case .year:
                shouldNotify = settings.notifyOnYearlyRecords
            case .allTime:
                shouldNotify = settings.notifyOnAllTimeRecords && isNewRecord  // Don't notify for replacements
            }

            if shouldNotify {
                recordManager.sendRecordNotification(recordType: recordType.rawValue, detail: newRecord)
            }

            // Generate thumbnail for the new record
            Task {
                await ThumbnailCache.shared.saveThumbnail(from: asset, for: newRecord.id)
            }

            debugLog("📸 Created record from photo: \(recordType.rawValue) (\(timeFrame.rawValue)) = \(value)")
            return true
        }

        return false
    }

    /// Geocode a location to get a place name
    private func geocodeLocation(_ location: CLLocation) async -> String? {
        // Check cache first
        if let cached = await sharedGeocodingCache.getCachedName(for: location.coordinate) {
            return cached
        }

        // Perform geocoding
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let name: String?
                if let city = placemark.locality, let country = placemark.country {
                    name = "\(city), \(country)"
                } else {
                    name = placemark.name
                }

                if let name = name {
                    await sharedGeocodingCache.setCachedName(name, for: location.coordinate)
                }
                return name
            }
        } catch {
            debugLog("📸 Geocoding error: \(error.localizedDescription)")
        }

        return nil
    }
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoLocationMonitor: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // We need to detect newly added photos
        // Fetch recent photos to find new additions
        Task { @MainActor in
            await self.handlePhotoLibraryChange(changeInstance)
        }
    }

    private func handlePhotoLibraryChange(_ changeInstance: PHChange) async {
        // Fetch the most recent photos to check for new additions
        // We look at photos from the last minute to catch newly taken photos
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 10  // Only check the most recent few

        // Filter to photos created in the last minute
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        fetchOptions.predicate = NSPredicate(format: "creationDate >= %@", oneMinuteAgo as NSDate)

        let recentPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        // Process any new photos with location data
        recentPhotos.enumerateObjects { asset, _, _ in
            // Only process photos that have location data and were just created
            if asset.location != nil {
                self.processNewPhoto(asset)
            }
        }
    }
}

// Note: PHPhotoLibrary.cloudIdentifier(for:) extension is defined in FormatUtils.swift
