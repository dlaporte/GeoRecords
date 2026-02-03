import Foundation
import CoreLocation
import UserNotifications
import CoreData

// MARK: - In-memory model for a record event
struct RecordDetail: Identifiable {
    var id = UUID()
    var value: Double           // For latitude, longitude, altitude, or distance
    var timestamp: Date         // Non-optional Date
    var coordinate: CLLocationCoordinate2D
    var altitude: Double
    var locationName: String?
    var recordType: String
    var timeFrame: TimeFrame    // Monthly, Yearly, or Lifetime
    var photoData: Data?        // Legacy: JPEG photo data (for old records)
    var photoAssetIdentifier: String?  // Local reference to photo in Apple Photos library
    var photoCloudIdentifier: String?  // iCloud identifier for cross-device photo access
    var notes: String?          // User-added notes/description for this record
    var dateAdded: Date?        // When record was imported/created
    var regionCode: String?     // For region records (state code, country code, continent name)
    var source: RecordSource?   // How this record was added (photo, location, home, manual)

    /// Initialize with coordinate validation
    /// - Warning: Coordinates are validated and must be valid. Invalid coordinates will trigger an assertion in debug builds.
    init(id: UUID = UUID(), value: Double, timestamp: Date, coordinate: CLLocationCoordinate2D, altitude: Double, locationName: String?, recordType: String, timeFrame: TimeFrame = .allTime, photoData: Data? = nil, photoAssetIdentifier: String? = nil, photoCloudIdentifier: String? = nil, notes: String? = nil, dateAdded: Date? = nil, regionCode: String? = nil, source: RecordSource? = nil) {
        self.id = id
        self.value = value
        self.timestamp = timestamp
        self.altitude = altitude
        self.locationName = locationName
        self.recordType = recordType
        self.timeFrame = timeFrame
        self.photoData = photoData
        self.photoAssetIdentifier = photoAssetIdentifier
        self.photoCloudIdentifier = photoCloudIdentifier
        self.notes = notes
        self.dateAdded = dateAdded
        self.regionCode = regionCode
        self.source = source

        // Validate coordinate
        if CLLocationCoordinate2DIsValid(coordinate) {
            self.coordinate = coordinate
        } else {
            // Log error and assert in debug builds
            let errorMsg = "⚠️ Invalid coordinate detected: lat=\(coordinate.latitude), lon=\(coordinate.longitude)"
            debugLog(errorMsg)
            #if DEBUG
            assertionFailure(errorMsg)
            #endif
            // In production, use a safe default (though this should never happen)
            self.coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
    }

    /// Formats the value based on record type and unit system
    func formattedValue(unitSystem: UnitSystem) -> String {
        return FormatUtils.formatValue(value: value, recordType: recordType, unitSystem: unitSystem)
    }

    /// Initialize from a Core Data RecordHistoryEntry
    /// - Parameter entry: The Core Data entry to convert
    /// - Returns: nil if the entry has no timestamp
    init?(from entry: RecordHistoryEntry) {
        guard let timestamp = entry.timestamp else { return nil }

        let timeFrame: TimeFrame = {
            if let timeFrameString = entry.timeFrame {
                // Normalize all lifetime variations to canonical form for backwards compatibility
                let normalizedString = lifetimeTimeFrameVariations.contains(timeFrameString) ? canonicalLifetimeTimeFrame : timeFrameString
                return TimeFrame(rawValue: normalizedString) ?? .allTime
            }
            return .allTime  // Default for old entries without timeFrame
        }()

        // Parse source from stored string
        let source: RecordSource? = {
            if let sourceString = entry.source {
                return RecordSource(rawValue: sourceString)
            }
            return nil
        }()

        self.init(
            id: entry.id ?? UUID(),
            value: entry.value,
            timestamp: timestamp,
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? unknownValueString,
            timeFrame: timeFrame,
            photoData: entry.photoData,
            photoAssetIdentifier: entry.photoAssetIdentifier,
            photoCloudIdentifier: entry.photoCloudIdentifier,
            notes: entry.notes,
            dateAdded: entry.dateAdded,
            regionCode: entry.regionCode,
            source: source
        )
    }
}

// MARK: - Protocol for Dependency Injection

/// Protocol defining the public interface of RecordManager for testing and mocking
@MainActor
protocol RecordManaging: ObservableObject {
    var showPhotoPrompt: Bool { get set }
    var pendingRecordForPhoto: (type: String, detail: RecordDetail)? { get set }

    // Badge counts for new records
    var newMonthlyRecordCount: Int { get }
    var newYearlyRecordCount: Int { get }
    var newAllTimeRecordCount: Int { get }

    func getRecord(type: String, timeFrame: TimeFrame) -> RecordDetail?
    func setRecord(type: String, timeFrame: TimeFrame, record: RecordDetail?)
    func updateRecords(with location: CLLocation, reverseGeocodedName: String?)
    func loadRecordsFromHistory()
    func resetRecords()
    func attachPhotoToRecord(recordType: String, photoData: Data?)
    func clearBadge(for timeFrame: TimeFrame)
}

@MainActor
class RecordManager: NSObject, ObservableObject, RecordManaging {
    static let shared = RecordManager()

    // MARK: - Storage

    /// Dictionary-based storage for all records (type -> timeframe -> record)
    private var records: [String: [TimeFrame: RecordDetail]] = [:]

    // MARK: - Other State

    // Photo prompt state
    @Published var showPhotoPrompt = false
    @Published var pendingRecordForPhoto: (type: String, detail: RecordDetail)?

    // Badge counts for new/unseen records per timeframe
    @Published var newMonthlyRecordCount = 0
    @Published var newYearlyRecordCount = 0
    @Published var newAllTimeRecordCount = 0

    // Geocoding status - tracks consecutive failures for user feedback
    @Published var consecutiveGeocodingFailures = 0
    private let maxGeocodingFailuresBeforeWarning = 3

    /// Returns true if geocoding is experiencing issues
    var hasGeocodingIssues: Bool {
        consecutiveGeocodingFailures >= maxGeocodingFailuresBeforeWarning
    }

    // MARK: - State Management

    /// Unified state for record updates and notifications
    private enum UpdateState {
        case idle
        case updating(pendingQueue: [CLLocation])
        case suppressingNotifications(until: Date)
        case blockingAlerts  // During photo import
    }

    private var updateState: UpdateState = .idle

    // Reusable geocoder instance to prevent memory leaks
    private let geocoder = CLGeocoder()
    private var lastGeocodingTime: Date?
    private var isGeocodingInProgress = false  // Prevent concurrent geocoding requests

    override init() {
        super.init()
        loadRecordsFromHistory()
    }

    // MARK: - Helper Methods for Record Access

    /// Get a record by type and timeframe
    func getRecord(type: String, timeFrame: TimeFrame) -> RecordDetail? {
        return records[type]?[timeFrame]
    }

    /// Set a record by type and timeframe
    func setRecord(type: String, timeFrame: TimeFrame, record: RecordDetail?) {
        // Notify observers that changes are coming
        objectWillChange.send()

        // Initialize nested dictionary if needed
        if records[type] == nil {
            records[type] = [:]
        }

        // Set the record
        records[type]?[timeFrame] = record

        // Post notification so other views can react to record changes
        NotificationCenter.default.post(name: .recordsDidChange, object: nil)
    }

    /// Clear a record by type and timeframe, both in-memory and in Core Data
    /// - Parameters:
    ///   - type: The record type (e.g., "Furthest North")
    ///   - timeFrame: The timeframe (.month, .year, .allTime)
    ///   - year: The year (required for month/year timeframes)
    ///   - month: The month (required for month timeframe, 1-12)
    func clearRecord(type: String, timeFrame: TimeFrame, year: Int? = nil, month: Int? = nil) {
        // Clear in-memory record
        setRecord(type: type, timeFrame: timeFrame, record: nil)

        // Delete from Core Data history
        switch timeFrame {
        case .daily:
            break  // Daily records are managed separately
        case .allTime:
            _ = RecordHistoryManager.shared.deleteAllRecords(type: type)
        case .year:
            if let year = year {
                _ = RecordHistoryManager.shared.deleteRecords(type: type, year: year)
            }
        case .month:
            if let year = year, let month = month {
                _ = RecordHistoryManager.shared.deleteRecords(type: type, year: year, month: month)
            }
        }
    }

    /// Conditionally updates a record if the new value is better than the existing one
    /// - Parameters:
    ///   - recordType: The type of record (e.g., "Furthest North")
    ///   - detail: The new record details
    ///   - timeFrame: The time frame for the record
    /// - Returns: True if the record was updated, false otherwise
    @discardableResult
    func updateRecordIfBetter(recordType: String, detail: RecordDetail, timeFrame: TimeFrame) -> Bool {
        let existing = getRecord(type: recordType, timeFrame: timeFrame)

        let shouldUpdate: Bool
        if let existing = existing,
           let type = RecordType.from(string: recordType) {
            shouldUpdate = type.shouldReplace(newValue: detail.value, oldValue: existing.value)
        } else {
            shouldUpdate = true
        }

        if shouldUpdate {
            setRecord(type: recordType, timeFrame: timeFrame, record: detail)
        }

        return shouldUpdate
    }

    /// Block all alerts during photo import
    func blockAlertsDuringImport(block: Bool) {
        if block {
            updateState = .blockingAlerts
        } else {
            updateState = .idle
        }
    }

    /// Call this after importing photos to suppress notifications for a period
    func suppressNotificationsAfterImport(durationSeconds: TimeInterval = 60) {
        let suppressUntil = Date().addingTimeInterval(durationSeconds)
        updateState = .suppressingNotifications(until: suppressUntil)
    }

    private var shouldSuppressNotifications: Bool {
        switch updateState {
        case .blockingAlerts:
            return true
        case .suppressingNotifications(let until):
            if Date() < until {
                return true
            } else {
                // Clear the suppression flag once expired
                updateState = .idle
                return false
            }
        case .idle, .updating:
            return false
        }
    }
    
    // MARK: - Load Records from Core Data
    func loadRecordsFromHistory() {
        // Remove any duplicate records before loading
        RecordHistoryManager.shared.removeDuplicates()

        let context = PersistenceController.shared.container.viewContext
        let settings = SettingsManager.shared

        // Single batch fetch to get all record types at once
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        do {
            // Fetch all entries
            var allEntries = try context.fetch(request)

            // Filter out records that are at home (likely test/bogus data)
            if let homeCoord = settings.homeCoordinate {
                let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
                let originalCount = allEntries.count
                allEntries = allEntries.filter { entry in
                    let entryLocation = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
                    let distance = entryLocation.distance(from: homeLocation)
                    return distance > atHomeRadiusMeters
                }
                let filteredCount = originalCount - allEntries.count
                if filteredCount > 0 {
                    debugLog("🏠 Filtered out \(filteredCount) records at home (within \(Int(atHomeRadiusMeters))m)")
                }
            }

            // Get current month and year boundaries
            let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

            // Filter entries by timeframe - consider time period hierarchy:
            // - "This Month" = records from current month (Monthly OR more granular)
            // - "This Year" = records from current year (Yearly OR Monthly from this year)
            // - "Lifetime" = all records (Lifetime OR any timeframe)

            // For Monthly: Monthly records from the current month
            // (Daily records are excluded - they're for chart granularity only and don't have photos)
            let monthEntries = allEntries.filter { entry in
                let tf = entry.timeFrame ?? ""
                guard let timestamp = entry.timestamp else { return false }
                return tf == TimeFrame.month.rawValue && timestamp >= startOfMonth
            }

            // For Yearly: any record from the current year period
            // Include "Yearly" records AND "Monthly" records from this year
            // (A January record should count toward "This Year" totals)
            let yearEntries = allEntries.filter { entry in
                let tf = entry.timeFrame ?? ""
                guard let timestamp = entry.timestamp else { return false }
                // Include Yearly records from current year
                if tf == TimeFrame.year.rawValue && timestamp >= startOfYear { return true }
                // Also include Monthly records from current year (they're part of this year!)
                if tf == TimeFrame.month.rawValue && timestamp >= startOfYear { return true }
                return false
            }

            // For Lifetime: ONLY records explicitly marked as Lifetime
            // We must respect the user's explicit Lifetime selection from the wizard
            // If we included Yearly/Monthly here, findExtreme() would pick the most extreme
            // across ALL timeframes, ignoring the user's Lifetime-specific choice
            let lifetimeEntries = allEntries.filter { entry in
                let tf = entry.timeFrame ?? ""
                return lifetimeTimeFrameVariations.contains(tf)
            }

            // Helper to find the best record from a group
            // IMPORTANT: We sort by dateAdded (most recent first) to respect user's wizard selections
            // The user explicitly chose a record in the wizard, so their most recent choice wins
            // over any older "more extreme" records that might still be in the database
            func findBestRecord(in entries: [RecordHistoryEntry]) -> RecordHistoryEntry? {
                return entries.sorted { entry1, entry2 in
                    // Sort by dateAdded descending (most recent first)
                    let date1 = entry1.dateAdded ?? entry1.timestamp ?? Date.distantPast
                    let date2 = entry2.dateAdded ?? entry2.timestamp ?? Date.distantPast
                    return date1 > date2
                }.first
            }

            // Helper to process records for a timeframe
            func loadRecordsForTimeFrame(entries: [RecordHistoryEntry], timeFrame: TimeFrame) {
                let grouped = Dictionary(grouping: entries) { entry -> String in
                    entry.recordType ?? unknownValueString
                }

                // Process each record type using RecordType enum
                for recordType in RecordType.allCases {
                    if let typeEntries = grouped[recordType.rawValue],
                       let entry = findBestRecord(in: typeEntries) {
                        if var record = makeRecordDetail(from: entry) {
                            record.timeFrame = timeFrame
                            setRecord(type: recordType.rawValue, timeFrame: timeFrame, record: record)
                        }
                    }
                }
            }

            // Load records for all three timeframes
            // Use filtered entries that respect the timeFrame field
            debugLog("📊 Loading records: \(monthEntries.count) monthly, \(yearEntries.count) yearly, \(lifetimeEntries.count) lifetime entries")
            debugLog("📅 Boundaries: startOfMonth=\(startOfMonth), startOfYear=\(startOfYear)")

            // Log what timeFrame values we actually have in the database
            let timeFrameValues = Dictionary(grouping: allEntries) { $0.timeFrame ?? "(nil)" }
            for (tf, entries) in timeFrameValues.sorted(by: { $0.key < $1.key }) {
                debugLog("📋 timeFrame='\(tf)': \(entries.count) entries")
            }

            loadRecordsForTimeFrame(entries: monthEntries, timeFrame: .month)
            loadRecordsForTimeFrame(entries: yearEntries, timeFrame: .year)
            loadRecordsForTimeFrame(entries: lifetimeEntries, timeFrame: .allTime)

            // Explicitly notify observers that records have changed
            objectWillChange.send()

            debugLog("Loaded all records from history for all timeframes")
        } catch {
            debugLog("Failed to load records: \(error.localizedDescription)")
        }
    }

    private func makeRecordDetail(from entry: RecordHistoryEntry) -> RecordDetail? {
        return RecordDetail(from: entry)
    }
    
    // MARK: - Update Records

    /// Parameters for checking all record types at a location
    private struct RecordCheckParams {
        let location: CLLocation
        let lat: Double
        let lon: Double
        let alt: Double
        let distanceMeters: Double?
        let reverseGeocodedName: String?
        let latThreshold: Double
        let lonThreshold: Double
        let altThreshold: Double
        let distanceThreshold: Double
    }

    /// Configuration for checking a single record type
    private struct RecordTypeCheck {
        let type: RecordType
        let value: Double
        let threshold: Double
        let compareAscending: Bool  // true means lower is better (south, west)
    }

    /// Check all record types for a given timeframe and return which ones were updated
    /// - Parameters:
    ///   - params: The location and threshold parameters
    ///   - timeFrame: The timeframe to check
    ///   - excludeTypes: Record types to skip (used in second pass)
    ///   - logSecondPass: Whether to log second pass updates
    /// - Returns: Set of record type strings that were updated
    @discardableResult
    private func checkAllRecordTypes(
        params: RecordCheckParams,
        timeFrame: TimeFrame,
        excludeTypes: Set<String> = [],
        logSecondPass: Bool = false
    ) -> Set<String> {
        var updated: Set<String> = []

        // Define all record type checks
        var checks: [RecordTypeCheck] = [
            RecordTypeCheck(type: .north, value: params.lat, threshold: params.latThreshold, compareAscending: false),
            RecordTypeCheck(type: .south, value: params.lat, threshold: params.latThreshold, compareAscending: true),
            RecordTypeCheck(type: .east, value: params.lon, threshold: params.lonThreshold, compareAscending: false),
            RecordTypeCheck(type: .west, value: params.lon, threshold: params.lonThreshold, compareAscending: true),
            RecordTypeCheck(type: .up, value: params.alt, threshold: params.altThreshold, compareAscending: false)
        ]

        // Add distance check if available
        if let distance = params.distanceMeters {
            checks.append(RecordTypeCheck(
                type: .fromHome,
                value: distance,
                threshold: params.distanceThreshold,
                compareAscending: false
            ))
        }

        // Check each record type
        for check in checks {
            guard !excludeTypes.contains(check.type.rawValue) else { continue }

            if checkAndUpdateRecord(
                type: check.type.rawValue,
                newValue: check.value,
                threshold: check.threshold,
                compareAscending: check.compareAscending,
                location: params.location,
                reverseGeocodedName: params.reverseGeocodedName,
                timeFrame: timeFrame
            ) {
                updated.insert(check.type.rawValue)
                if logSecondPass {
                    debugLog("📍 Second pass: Also set \(check.type.rawValue) record")
                }
            }
        }

        return updated
    }

    /// Helper to check and update a record for a specific timeframe
    /// - Returns: true if the record was updated, false otherwise
    @discardableResult
    private func checkAndUpdateRecord(
        type: String,
        newValue: Double,
        threshold: Double,
        compareAscending: Bool,  // true means lower is better (south, west, down)
        location: CLLocation,
        reverseGeocodedName: String?,
        timeFrame: TimeFrame
    ) -> Bool {
        let currentRecord = getRecord(type: type, timeFrame: timeFrame)
        let now = Date()
        let settings = SettingsManager.shared

        if let current = currentRecord {
            // Calculate delta based on comparison direction
            let delta = compareAscending ? (current.value - newValue) : (newValue - current.value)

            if delta > threshold {
                let newRecord = RecordDetail(
                    value: newValue,
                    timestamp: now,
                    coordinate: location.coordinate,
                    altitude: location.altitude,
                    locationName: reverseGeocodedName,
                    recordType: type,
                    timeFrame: timeFrame,
                    source: .location
                )

                // Try to save to Core Data first - only update in-memory if successful
                let saveSucceeded = RecordHistoryManager.shared.addRecord(recordType: type, detail: newRecord)

                if saveSucceeded {
                    setRecord(type: type, timeFrame: timeFrame, record: newRecord)

                    // Increment badge for this timeframe
                    incrementBadge(for: timeFrame)

                    // Photo prompts only for all-time records
                    if timeFrame == .allTime {
                        promptForPhoto(recordType: type, detail: newRecord)
                    }

                    // Check notification settings based on timeframe
                    let shouldNotify: Bool
                    switch timeFrame {
                    case .daily:
                        shouldNotify = false  // Never notify for daily records
                    case .month:
                        shouldNotify = settings.notifyOnMonthlyRecords
                    case .year:
                        shouldNotify = settings.notifyOnYearlyRecords
                    case .allTime:
                        shouldNotify = settings.notifyOnAllTimeRecords
                    }

                    if shouldNotify && !shouldSuppressNotifications {
                        sendRecordNotification(recordType: type, detail: newRecord)
                    }

                    debugLog("NEW RECORD: \(type) (\(timeFrame.rawValue)) updated to \(newValue)")
                    return true
                } else {
                    debugLog("❌ Failed to persist record to Core Data - in-memory state NOT updated")
                    return false
                }
            }
        } else {
            // Set initial record for this timeframe
            let newRecord = RecordDetail(
                value: newValue,
                timestamp: now,
                coordinate: location.coordinate,
                altitude: location.altitude,
                locationName: reverseGeocodedName,
                recordType: type,
                timeFrame: timeFrame,
                source: .location
            )

            // Try to save to Core Data first
            let saveSucceeded = RecordHistoryManager.shared.addRecord(recordType: type, detail: newRecord)

            if saveSucceeded {
                setRecord(type: type, timeFrame: timeFrame, record: newRecord)

                // Photo prompts only for all-time records
                if timeFrame == .allTime {
                    promptForPhoto(recordType: type, detail: newRecord)
                }

                // Send notification for initial monthly/yearly records (they're meaningful milestones)
                // but not for all-time (first-time setup isn't noteworthy)
                let shouldNotify: Bool
                switch timeFrame {
                case .daily:
                    shouldNotify = false
                case .month:
                    shouldNotify = settings.notifyOnMonthlyRecords
                case .year:
                    shouldNotify = settings.notifyOnYearlyRecords
                case .allTime:
                    shouldNotify = false  // Don't notify for initial all-time records
                }

                if shouldNotify && !shouldSuppressNotifications {
                    sendRecordNotification(recordType: type, detail: newRecord)
                }

                return true
            } else {
                debugLog("❌ Failed to persist initial record to Core Data - in-memory state NOT updated")
                return false
            }
        }
        return false
    }

    // MARK: - Geocoding Helper

    /// Attempts to geocode a location, using cache and throttling
    /// - Parameter location: The location to geocode
    /// - Returns: The location name, or empty string if geocoding fails/is throttled
    private func geocodeLocationIfNeeded(_ location: CLLocation) async -> String? {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        // Check cache first
        if let cachedName = await sharedGeocodingCache.getCachedName(for: location.coordinate) {
            return cachedName
        }

        // Check if geocoding is already in progress
        if isGeocodingInProgress {
            return ""
        }

        // Throttle geocoding to avoid rate limits
        let now = Date()
        if let lastTime = lastGeocodingTime, now.timeIntervalSince(lastTime) < geocodingThrottleInterval {
            return ""
        }

        // Cancel any pending geocoding requests
        if geocoder.isGeocoding {
            geocoder.cancelGeocode()
        }
        lastGeocodingTime = now
        isGeocodingInProgress = true

        // Perform geocoding
        debugLog("🌐 Geocoding location (\(lat), \(lon))")

        return await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                // Process result on background thread
                let name: String?
                let shouldResetFailures: Bool
                let shouldIncrementFailures: Bool

                if let error = error {
                    debugLog("Geocoding error: \(error.localizedDescription)")
                    name = nil
                    shouldResetFailures = false
                    shouldIncrementFailures = true
                } else if let placemark = placemarks?.first {
                    shouldResetFailures = true
                    shouldIncrementFailures = false

                    if let city = placemark.locality, let country = placemark.country {
                        name = "\(city), \(country)"
                    } else if let placemarkName = placemark.name {
                        name = placemarkName
                    } else {
                        name = nil
                    }
                } else {
                    name = nil
                    shouldResetFailures = false
                    shouldIncrementFailures = false
                }

                // Single coordinated update to @MainActor properties and cache
                Task {
                    // Update all @MainActor properties atomically
                    await MainActor.run {
                        self.isGeocodingInProgress = false

                        if shouldIncrementFailures {
                            self.consecutiveGeocodingFailures += 1
                            if self.hasGeocodingIssues {
                                debugLog("⚠️ Multiple geocoding failures detected (\(self.consecutiveGeocodingFailures))")
                            }
                        } else if shouldResetFailures {
                            self.consecutiveGeocodingFailures = 0
                        }
                    }

                    // Cache the result if successful
                    if let name = name {
                        await sharedGeocodingCache.setCachedName(name, for: location.coordinate)
                        debugLog("💾 Cached location for (\(lat), \(lon)): \(name)")
                    }

                    // Resume continuation after all updates complete
                    continuation.resume(returning: name)
                }
            }
        }
    }

    /// Update daily records for all directions based on current location
    /// Daily records track the extreme values for each day (used for "This Month" charts)
    private func updateDailyRecords(location: CLLocation, locationName: String?) {
        RecordHistoryManager.shared.updateAllDailyRecords(
            location: location,
            locationName: locationName,
            homeCoordinate: SettingsManager.shared.homeCoordinate
        )
    }

    /// Updates all records with a new location, checking each timeframe for new extremes
    /// - Parameters:
    ///   - location: The location to check against current records
    ///   - reverseGeocodedName: Optional location name (will geocode if nil)
    /// - Note: Automatically persists to Core Data and sends notifications when records are broken
    func updateRecords(with location: CLLocation, reverseGeocodedName: String? = nil) {
        // Serialize updates to prevent race conditions
        switch updateState {
        case .updating(let pendingQueue):
            // Already updating, add to queue
            updateState = .updating(pendingQueue: pendingQueue + [location])
            return
        case .blockingAlerts, .suppressingNotifications:
            // Don't interrupt these states
            break
        case .idle:
            // Ready to update
            break
        }

        // Validate location before processing
        switch validateLocation(location) {
        case .nullIsland:
            debugLog("⚠️ Skipping Null Island location - invalid GPS data")
            return
        case .unrealisticAltitude(let meters):
            debugLog("⚠️ Skipping unrealistic altitude (\(Int(meters))m) - likely airplane or bad GPS")
            return
        case .valid:
            break
        }

        // Skip locations at home (likely test data)
        if let homeCoord = SettingsManager.shared.homeCoordinate {
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let distanceFromHomeMeters = location.distance(from: homeLocation)
            if distanceFromHomeMeters <= atHomeRadiusMeters {
                debugLog("🏠 Skipping location at home (within \(Int(distanceFromHomeMeters))m)")
                return
            }
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let alt = location.altitude

        let previousState = updateState
        updateState = .updating(pendingQueue: [])
        defer {
            // Process all pending updates
            if case .updating(let pendingQueue) = updateState, !pendingQueue.isEmpty {
                // Process each queued location
                for pendingLocation in pendingQueue {
                    // Reset state for each iteration
                    updateState = .updating(pendingQueue: [])
                    updateRecords(with: pendingLocation, reverseGeocodedName: nil)
                }
            }
            // Restore previous state if it wasn't .idle or .updating
            switch previousState {
            case .suppressingNotifications, .blockingAlerts:
                updateState = previousState
            default:
                updateState = .idle
            }
        }

        if reverseGeocodedName == nil {
            // Need to geocode first
            Task {
                let locationName = await geocodeLocationIfNeeded(location)
                await MainActor.run {
                    self.updateRecords(with: location, reverseGeocodedName: locationName)
                }
            }
            return
        }

        // Record daily extremes for this location (used for "This Month" charts)
        let settings = SettingsManager.shared
        updateDailyRecords(location: location, locationName: reverseGeocodedName)

        let latDelta = settings.minLatitudeDelta
        let lonDelta = settings.minLongitudeDelta
        let altDeltaMeters = settings.minAltitudeDeltaMeters
        let distanceDeltaMeters = settings.minDistanceDeltaMeters

        let distanceMeters = distanceFromHome(location: location, settings: settings)

        // Build params struct for record checking
        let params = RecordCheckParams(
            location: location,
            lat: lat,
            lon: lon,
            alt: alt,
            distanceMeters: distanceMeters,
            reverseGeocodedName: reverseGeocodedName,
            latThreshold: latDelta,
            lonThreshold: lonDelta,
            altThreshold: altDeltaMeters,
            distanceThreshold: distanceDeltaMeters
        )

        // FIRST PASS: Check all records with normal thresholds
        // Only update records that exceed the configured delta thresholds
        var updatedRecords: [TimeFrame: Set<String>] = [:]
        for timeFrame in TimeFrame.allCases {
            updatedRecords[timeFrame] = checkAllRecordTypes(params: params, timeFrame: timeFrame)
        }

        // SECOND PASS: Zero-threshold check for "extreme locations"
        //
        // Rationale: If a location is extreme enough to set ANY record (e.g., Furthest North),
        // then it's likely significant enough to check if it sets other records too, even if
        // those wouldn't normally pass the threshold.
        //
        // Example: User travels to Alaska (new Furthest North):
        // - First pass: Sets Furthest North (exceeded 0.5° threshold)
        // - Second pass: Also sets Furthest West (was 0.3° west of previous, below threshold)
        // - Result: Captures both records from this significant trip, not just one
        //
        // This prevents missing closely-related records at the same significant location.
        let zeroThresholdParams = RecordCheckParams(
            location: location,
            lat: lat,
            lon: lon,
            alt: alt,
            distanceMeters: distanceMeters,
            reverseGeocodedName: reverseGeocodedName,
            latThreshold: 0,
            lonThreshold: 0,
            altThreshold: 0,
            distanceThreshold: 0
        )

        for timeFrame in TimeFrame.allCases {
            guard let updated = updatedRecords[timeFrame], !updated.isEmpty else { continue }
            debugLog("📍 Second pass for \(timeFrame.rawValue): checking remaining records at this extreme location")
            checkAllRecordTypes(
                params: zeroThresholdParams,
                timeFrame: timeFrame,
                excludeTypes: updated,
                logSecondPass: true
            )
        }
    }
    
    // MARK: - Distance from Home Calculation
    func distanceFromHome(location: CLLocation, settings: SettingsManager) -> Double? {
        guard let homeCoord = settings.homeCoordinate else {
            debugLog("No home coordinate set; cannot compute distance from home.")
            return nil
        }
        return distanceBetween(from: location.coordinate, to: homeCoord)
    }
    
    // MARK: - Send Notification with Deep Link Info
    func sendRecordNotification(recordType: String, detail: RecordDetail) {
        // Check notification authorization before attempting to send
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            guard settings.authorizationStatus == .authorized else {
                debugLog("⚠️ Cannot send notification - authorization status: \(settings.authorizationStatus.rawValue)")
                return
            }

            let content = UNMutableNotificationContent()

            // Use shared formatting logic
            let formattedValue = detail.formattedValue(unitSystem: SettingsManager.shared.unitSystem)

            // Updated notification: Split text into title and body for better wrapping.
            content.title = "You've set a new \(recordType) record"
            content.body = "(\(formattedValue))"
            content.sound = .default

            content.userInfo = ["recordType": recordType, "timeFrame": detail.timeFrame.rawValue]

            let request = UNNotificationRequest(identifier: NotificationIdentifier.newRecord(type: recordType), content: content, trigger: nil)

            do {
                try await center.add(request)
                debugLog("✅ Notification sent successfully for \(recordType)")
            } catch {
                debugLog("❌ Failed to send notification: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Photo Attachment
    func attachPhotoToRecord(recordType: String, photoData: Data?) {
        // Only all-time records can have photos (since we only prompt for all-time records)
        guard var record = getRecord(type: recordType, timeFrame: .allTime) else { return }

        record.photoData = photoData
        setRecord(type: recordType, timeFrame: .allTime, record: record)

        // Update Core Data with photo
        RecordHistoryManager.shared.updateRecordPhoto(recordId: record.id, photoData: photoData)
    }

    // MARK: - Trigger Photo Prompt
    func promptForPhoto(recordType: String, detail: RecordDetail) {
        // Block during import
        if case .blockingAlerts = updateState {
            return
        }

        // Only prompt if enabled in settings
        guard SettingsManager.shared.photoPromptsEnabled else { return }

        pendingRecordForPhoto = (recordType, detail)
        showPhotoPrompt = true
    }

    // MARK: - Reset In-Memory Records
    func resetRecords() {
        objectWillChange.send()
        records.removeAll()
    }

    // MARK: - Badge Management

    /// Increment badge count for a timeframe when a new record is set
    func incrementBadge(for timeFrame: TimeFrame) {
        switch timeFrame {
        case .daily:
            break  // No badge for daily records
        case .month:
            newMonthlyRecordCount += 1
        case .year:
            newYearlyRecordCount += 1
        case .allTime:
            newAllTimeRecordCount += 1
        }
        updateAppIconBadge()
    }

    /// Clear badge count for a specific timeframe (called when user views that timeframe)
    func clearBadge(for timeFrame: TimeFrame) {
        switch timeFrame {
        case .daily:
            break  // No badge for daily records
        case .month:
            newMonthlyRecordCount = 0
        case .year:
            newYearlyRecordCount = 0
        case .allTime:
            newAllTimeRecordCount = 0
        }
        updateAppIconBadge()
    }

    /// Clear all badges
    func clearAllBadges() {
        newMonthlyRecordCount = 0
        newYearlyRecordCount = 0
        newAllTimeRecordCount = 0
        updateAppIconBadge()
    }

    /// Total number of unseen records across all timeframes
    var totalUnseenRecordCount: Int {
        newMonthlyRecordCount + newYearlyRecordCount + newAllTimeRecordCount
    }

    /// Update the app icon badge with the total unseen record count
    private func updateAppIconBadge() {
        let total = totalUnseenRecordCount
        UNUserNotificationCenter.current().setBadgeCount(total) { error in
            if let error = error {
                debugLog("Failed to update badge: \(error.localizedDescription)")
            }
        }
    }
}
