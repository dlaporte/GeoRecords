import Foundation
import Photos
import CoreLocation
import UserNotifications

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

    // MARK: - Catch-Up Scanning

    private static let lastCatchUpKey = "lastPhotoCatchUpDate"
    private static let catchUpWindowCapDays = 90
    private static let catchUpMinimumInterval: TimeInterval = 15 * 60
    private static let catchUpAssetCap = 2000
    /// Overlap so a photo taken exactly at a scan boundary can't fall between two scans
    private static let catchUpOverlapSeconds: TimeInterval = 3600
    private var isCatchUpRunning = false

    /// Scan photos taken since the app was last active and auto-add any records they set.
    /// The live change observer only sees photos while the app is running; this catches
    /// the gap after force-quit or reboot. Individual record notifications are suppressed
    /// in favor of a single digest. Reprocessing already-counted photos is harmless:
    /// their values no longer beat the records they set.
    func performCatchUpScan() async {
        guard !isCatchUpRunning else { return }

        // Data-restore gate: catch-up is the most likely writer to race an iCloud
        // re-sync (shared photo library recreates the other device's records with new
        // IDs). Return WITHOUT stamping lastCatchUpDate so the window is preserved
        // and this pass simply runs later, after the gate clears.
        guard !SettingsManager.shared.needsDataRestore else {
            debugLog("🚧 Restore gate armed - deferring photo catch-up scan")
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let defaults = UserDefaults(suiteName: "group.com.georecords.shared") ?? .standard
        let now = Date()

        guard let lastCatchUp = defaults.object(forKey: Self.lastCatchUpKey) as? Date else {
            // First run: don't sweep the whole library automatically — the import wizard
            // owns deep history. Start tracking from now.
            defaults.set(now, forKey: Self.lastCatchUpKey)
            return
        }

        // Rapid launch/foreground flips shouldn't rescan
        guard now.timeIntervalSince(lastCatchUp) >= Self.catchUpMinimumInterval else { return }

        isCatchUpRunning = true
        defer { isCatchUpRunning = false }

        // Warm the region boundaries OFF the main actor first: the first region lookup
        // otherwise blocks the main thread behind the ~36MB GeoJSON parse
        await Task.detached(priority: .utility) {
            RegionLookupService.shared.loadBoundaries()
        }.value

        // Cap the window — gaps deeper than the cap are the import wizard's job
        let capStart = Calendar.current.date(byAdding: .day, value: -Self.catchUpWindowCapDays, to: now) ?? lastCatchUp
        let windowStart = max(lastCatchUp, capStart).addingTimeInterval(-Self.catchUpOverlapSeconds)

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "creationDate > %@", windowStart as NSDate)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.fetchLimit = Self.catchUpAssetCap

        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        guard assets.count > 0 else {
            defaults.set(now, forKey: Self.lastCatchUpKey)
            return
        }

        debugLog("📸 Catch-up scan: checking \(assets.count) photo(s) taken since \(windowStart)")

        let settings = SettingsManager.shared
        let regionManager = RegionTrackingManager.shared
        let pendingBefore = regionManager.pendingRegions.count
        var recordsCreated = 0
        var lastProcessedDate: Date?

        for index in 0..<assets.count {
            // Keep the main actor breathing between photos
            await Task.yield()

            let asset = assets.object(at: index)
            lastProcessedDate = asset.creationDate ?? lastProcessedDate

            // Periodically stamp progress so an interrupted pass RESUMES here
            // instead of repeating (or, worse, skipping) work
            if index % 100 == 99, let progressDate = lastProcessedDate {
                defaults.set(progressDate, forKey: Self.lastCatchUpKey)
            }

            guard let location = asset.location else { continue }

            // Same guards as the live path: skip at-home and Null Island fixes
            // (in-flight photos stay eligible for everything except the altitude record)
            if let homeCoord = settings.homeCoordinate {
                let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
                if location.distance(from: homeLocation) <= atHomeRadiusMeters { continue }
            }
            if case .nullIsland = validateLocation(location) { continue }

            // Geocoding is skipped here (rate limits would stall the pass);
            // BackgroundGeocoder backfills names afterwards
            recordsCreated += await checkPhotoForRecords(asset: asset, location: location, sendNotifications: false, geocodeNames: false)

            // Regions: photos are the only evidence while the app was closed.
            // ALREADY-visited regions are enriched through the normal path (earlier
            // first-visit date, photo attachment); NEW regions are queued for the
            // user to confirm — an AirDropped photo must not silently add a country.
            // Flyover guard: recordVisit checks altitude itself; for the queue, apply
            // the same rule here.
            if case .valid = validateLocation(location) {
                if let info = RegionLookupService.shared.region(for: location.coordinate) {
                    if regionManager.isRegionVisited(code: info.code) {
                        regionManager.recordVisit(
                            coordinate: location.coordinate,
                            date: asset.creationDate ?? Date(),
                            source: .photo,
                            altitude: location.altitude
                        )
                    } else {
                        regionManager.queuePendingVisit(
                            info: info,
                            date: asset.creationDate ?? Date(),
                            coordinate: location.coordinate,
                            altitude: location.altitude
                        )
                    }
                }
            }
        }

        // Completion stamp: if we hit the asset cap there are more photos in the window —
        // leave the stamp at the last processed photo so the next pass CONTINUES from
        // there. Otherwise stamp the scan start so nothing is rescanned.
        if assets.count >= Self.catchUpAssetCap, let resumeDate = lastProcessedDate {
            defaults.set(resumeDate, forKey: Self.lastCatchUpKey)
            debugLog("📸 Catch-up hit the \(Self.catchUpAssetCap)-photo cap; will continue from \(resumeDate) next pass")
        } else {
            defaults.set(now, forKey: Self.lastCatchUpKey)
        }

        let pendingAdded = regionManager.pendingRegions.count - pendingBefore

        if recordsCreated > 0 {
            RecordManager.shared.loadRecordsFromHistory()
            // Backfill the location names we skipped, with proper rate-limit pacing
            Task {
                await BackgroundGeocoder.shared.geocodeMissingLocations()
            }
        }
        if recordsCreated > 0 || pendingAdded > 0 {
            sendCatchUpDigest(recordCount: recordsCreated, pendingRegionCount: pendingAdded)
        }
        debugLog("📸 Catch-up scan complete: \(recordsCreated) record(s) created, \(pendingAdded) region(s) queued")
    }

    /// One digest notification for the whole catch-up pass, instead of per-record banners
    private func sendCatchUpDigest(recordCount: Int, pendingRegionCount: Int) {
        let settings = SettingsManager.shared
        guard settings.notifyOnMonthlyRecords || settings.notifyOnYearlyRecords || settings.notifyOnAllTimeRecords || settings.notifyOnNewRegion else {
            return
        }

        Task {
            let center = UNUserNotificationCenter.current()
            let notificationSettings = await center.notificationSettings()
            guard notificationSettings.authorizationStatus == .authorized else { return }

            var parts: [String] = []
            if recordCount > 0 {
                parts.append(recordCount == 1 ? "1 new record" : "\(recordCount) new records")
            }
            if pendingRegionCount > 0 {
                parts.append(pendingRegionCount == 1 ? "1 new place to confirm" : "\(pendingRegionCount) new places to confirm")
            }
            guard !parts.isEmpty else { return }

            let content = UNMutableNotificationContent()
            content.title = "While you were away"
            content.body = "GeoRecords found \(parts.joined(separator: " and ")) in your recent photos."
            content.sound = .default
            // Deep link: pending regions live on the Regions tab; records land on Records
            content.userInfo = ["deepLink": pendingRegionCount > 0 ? "regions" : "records"]

            let request = UNNotificationRequest(identifier: NotificationIdentifier.photoCatchUpDigest, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// Process a new photo asset to check for records
    private func processNewPhoto(_ asset: PHAsset) {
        // Data-restore gate: no record creation until the user completes a restore path
        guard !SettingsManager.shared.needsDataRestore else { return }

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

        // Validate the location. Unrealistic altitude (in-flight photo) is NOT a reject:
        // checkPhotoForRecords keeps the photo for every record except altitude,
        // matching RecordManager.updateRecords and the library scanner.
        if case .nullIsland = validateLocation(location) {
            debugLog("📸 Photo location is Null Island, skipping")
            return
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
    /// - Parameters:
    ///   - sendNotifications: false during catch-up scans, where the caller
    ///     posts a single digest instead of per-photo banners
    ///   - geocodeNames: false during catch-up scans — sequential CLGeocoder calls are
    ///     rate-limited (~50/min) and would stall the pass; BackgroundGeocoder backfills
    ///     names afterwards with proper pacing
    /// - Returns: number of distinct record TYPES this photo set (for digest counting)
    @discardableResult
    func checkPhotoForRecords(asset: PHAsset, location: CLLocation, sendNotifications: Bool = true, geocodeNames: Bool = true) async -> Int {
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

        // Reverse geocode the location (skipped in catch-up; backfilled later)
        let locationName = geocodeNames ? await geocodeLocation(location) : nil

        // Track if we created any records
        var recordsCreated: [String] = []

        // Define checks for each record type. An in-flight photo (unrealistic altitude)
        // still counts for N/S/E/W/from-home — only the altitude record can't trust it
        var allChecks: [(type: RecordType, value: Double, threshold: Double)] = [
            (.north, lat, latThreshold),
            (.south, lat, latThreshold),
            (.east, lon, lonThreshold),
            (.west, lon, lonThreshold)
        ]

        if case .valid = validateLocation(latitude: lat, longitude: lon, altitude: alt) {
            allChecks.append((.up, alt, altThreshold))
        }

        // Add distance from home if available
        if let distance = distanceFromHome {
            allChecks.append((.fromHome, distance, distanceThreshold))
        }

        // Check each record type across all timeframes, collecting notifiable timeframes
        // per type so we can post ONE "biggest achievement" notification per type
        var notifiableTimeFrames: [String: Set<TimeFrame>] = [:]

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

                if result.created {
                    recordsCreated.append("\(check.type.rawValue) (\(timeFrame.rawValue))")
                }
                if result.notifiable {
                    notifiableTimeFrames[check.type.rawValue, default: []].insert(timeFrame)
                }
            }
        }

        // One notification per record type with the most significant timeframe beaten
        // (lifetime > yearly > monthly), matching RecordManager.updateRecords —
        // and matching its import-suppression window too
        if sendNotifications && !RecordManager.shared.isSuppressingNotifications {
            let recordManager = RecordManager.shared
            for (type, timeFrames) in notifiableTimeFrames {
                guard let best = TimeFrame.mostSignificant(of: timeFrames),
                      let detail = recordManager.getRecord(type: type, timeFrame: best) else { continue }
                recordManager.sendRecordNotification(recordType: type, detail: detail)
            }
        }

        if !recordsCreated.isEmpty {
            debugLog("📸 Photo created records: \(recordsCreated.joined(separator: ", "))")
        }
        // Distinct record types, not rows: one location beating monthly+yearly+lifetime
        // is ONE achievement in digest terms, not three
        return notifiableOrCreatedTypeCount(from: recordsCreated)
    }

    /// Count distinct record types from "Type (TimeFrame)" entries
    private func notifiableOrCreatedTypeCount(from entries: [String]) -> Int {
        Set(entries.compactMap { $0.split(separator: "(").first?.trimmingCharacters(in: .whitespaces) }).count
    }

    /// Check if a photo should create or replace a record.
    /// Does NOT post notifications: checkPhotoForRecords aggregates the notifiable
    /// results into one "biggest achievement" notification per record type.
    private func checkAndCreateRecord(
        recordType: RecordType,
        value: Double,
        threshold: Double,
        location: CLLocation,
        locationName: String?,
        timeFrame: TimeFrame,
        asset: PHAsset,
        cloudId: String?
    ) async -> (created: Bool, notifiable: Bool) {
        let recordManager = RecordManager.shared
        let historyManager = RecordHistoryManager.shared
        let settings = SettingsManager.shared
        let now = Date()

        // A photo must compete against the records of ITS OWN period: a July 30 photo
        // scanned in August compares against July's monthly record, not August's.
        // Only current-period wins update the in-memory slots or notify.
        let photoDate = asset.creationDate ?? now
        let calendar = Calendar.current
        let isCurrentPeriod: Bool
        switch timeFrame {
        case .daily, .allTime:
            isCurrentPeriod = true
        case .month:
            isCurrentPeriod = calendar.isDate(photoDate, equalTo: now, toGranularity: .month)
        case .year:
            isCurrentPeriod = calendar.isDate(photoDate, equalTo: now, toGranularity: .year)
        }

        let currentRecord: RecordDetail?
        if isCurrentPeriod {
            currentRecord = recordManager.getRecord(type: recordType.rawValue, timeFrame: timeFrame)
        } else {
            let components = calendar.dateComponents([.year, .month], from: photoDate)
            switch timeFrame {
            case .month:
                currentRecord = historyManager.getBestRecord(type: recordType.rawValue, year: components.year ?? 0, month: components.month ?? 0)
            case .year:
                currentRecord = historyManager.getBestRecord(type: recordType.rawValue, year: components.year ?? 0)
            default:
                currentRecord = nil
            }
        }

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
        // Only meaningful for the current period (the "recent" window is measured from now)
        let shouldReplaceRecent: Bool
        if isCurrentPeriod, !isNewRecord, let current = currentRecord {
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
            return (created: false, notifiable: false)
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
            // In-memory slots, badges, and notifications describe the CURRENT period;
            // a past-period row only belongs in history
            if isCurrentPeriod {
                recordManager.setRecord(type: recordType.rawValue, timeFrame: timeFrame, record: newRecord)
                recordManager.incrementBadge(for: timeFrame)
            }

            // Notification eligibility based on settings (posted by the caller)
            let shouldNotify: Bool
            switch timeFrame {
            case _ where !isCurrentPeriod:
                shouldNotify = false
            case .daily:
                shouldNotify = false
            case .month:
                shouldNotify = settings.notifyOnMonthlyRecords
            case .year:
                shouldNotify = settings.notifyOnYearlyRecords
            case .allTime:
                shouldNotify = settings.notifyOnAllTimeRecords && isNewRecord  // Don't notify for replacements
            }

            // Generate thumbnail for the new record
            Task {
                await ThumbnailCache.shared.saveThumbnail(from: asset, for: newRecord.id)
            }

            debugLog("📸 Created record from photo: \(recordType.rawValue) (\(timeFrame.rawValue)) = \(value)")
            return (created: true, notifiable: shouldNotify)
        }

        return (created: false, notifiable: false)
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
