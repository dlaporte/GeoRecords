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
    var timeFrame: TimeFrame    // Monthly, Yearly, or All Time
    var photoData: Data?        // JPEG photo data captured when record was set
    var notes: String?          // User-added notes/description for this record

    /// Initialize with coordinate validation
    /// - Warning: Coordinates are validated and must be valid. Invalid coordinates will trigger an assertion in debug builds.
    init(id: UUID = UUID(), value: Double, timestamp: Date, coordinate: CLLocationCoordinate2D, altitude: Double, locationName: String?, recordType: String, timeFrame: TimeFrame = .allTime, photoData: Data? = nil, notes: String? = nil) {
        self.id = id
        self.value = value
        self.timestamp = timestamp
        self.altitude = altitude
        self.locationName = locationName
        self.recordType = recordType
        self.timeFrame = timeFrame
        self.photoData = photoData
        self.notes = notes

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
                return TimeFrame(rawValue: timeFrameString) ?? .allTime
            }
            return .allTime  // Default for old entries without timeFrame
        }()

        self.init(
            id: entry.id ?? UUID(),
            value: entry.value,
            timestamp: timestamp,
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? "Unknown",
            timeFrame: timeFrame,
            photoData: entry.photoData,
            notes: entry.notes
        )
    }
}

// MARK: - Protocol for Dependency Injection

/// Protocol defining the public interface of RecordManager for testing and mocking
@MainActor
protocol RecordManaging: ObservableObject {
    var showPhotoPrompt: Bool { get set }
    var pendingRecordForPhoto: (type: String, detail: RecordDetail)? { get set }

    func getRecord(type: String, timeFrame: TimeFrame) -> RecordDetail?
    func setRecord(type: String, timeFrame: TimeFrame, record: RecordDetail?)
    func updateRecords(with location: CLLocation, reverseGeocodedName: String?)
    func loadRecordsFromHistory()
    func resetRecords()
    func attachPhotoToRecord(recordType: String, photoData: Data?)
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
    private let geocodingThrottleInterval: TimeInterval = 60  // Minimum 60s between geocoding requests
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

        // Single batch fetch to get all record types at once
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        do {
            // Fetch all entries
            let allEntries = try context.fetch(request)

            // Get current month and year boundaries
            let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

            // Filter entries by timeframe
            let monthEntries = allEntries.filter { entry in
                guard let timestamp = entry.timestamp else { return false }
                return timestamp >= startOfMonth
            }
            let yearEntries = allEntries.filter { entry in
                guard let timestamp = entry.timestamp else { return false }
                return timestamp >= startOfYear
            }

            // Helper to find extreme record from group
            func findExtreme(in entries: [RecordHistoryEntry], ascending: Bool) -> RecordHistoryEntry? {
                return entries.sorted { ascending ? $0.value < $1.value : $0.value > $1.value }.first
            }

            // Helper to process records for a timeframe
            func loadRecordsForTimeFrame(entries: [RecordHistoryEntry], timeFrame: TimeFrame) {
                let grouped = Dictionary(grouping: entries) { entry -> String in
                    entry.recordType ?? "Unknown"
                }

                // Process each record type
                let recordTypes = [
                    ("Furthest North", false),
                    ("Furthest South", true),
                    ("Furthest East", false),
                    ("Furthest West", true),
                    ("Furthest Up", false),
                    ("Furthest Down", true),
                    ("Furthest from Home", false)
                ]

                for (type, ascending) in recordTypes {
                    if let typeEntries = grouped[type], let entry = findExtreme(in: typeEntries, ascending: ascending) {
                        if var record = makeRecordDetail(from: entry) {
                            record.timeFrame = timeFrame
                            setRecord(type: type, timeFrame: timeFrame, record: record)
                        }
                    }
                }
            }

            // Load records for all three timeframes
            loadRecordsForTimeFrame(entries: monthEntries, timeFrame: .month)
            loadRecordsForTimeFrame(entries: yearEntries, timeFrame: .year)
            loadRecordsForTimeFrame(entries: allEntries, timeFrame: .allTime)

            debugLog("Loaded all records from history for all timeframes")
        } catch {
            debugLog("Failed to load records: \(error.localizedDescription)")
        }
    }

    private func makeRecordDetail(from entry: RecordHistoryEntry) -> RecordDetail? {
        return RecordDetail(from: entry)
    }
    
    // MARK: - Update Records

    /// Helper to check and update a record for a specific timeframe
    private func checkAndUpdateRecord(
        type: String,
        newValue: Double,
        threshold: Double,
        compareAscending: Bool,  // true means lower is better (south, west, down)
        location: CLLocation,
        reverseGeocodedName: String?,
        timeFrame: TimeFrame
    ) {
        let currentRecord = getRecord(type: type, timeFrame: timeFrame)
        let now = Date()
        let settings = SettingsManager.shared

        if let current = currentRecord {
            // Calculate delta based on comparison direction
            let delta = compareAscending ? (current.value - newValue) : (newValue - current.value)

            debugLog("\(type) (\(timeFrame.rawValue)): new=\(newValue), current=\(current.value), delta=\(delta)")

            if delta > threshold {
                let newRecord = RecordDetail(
                    value: newValue,
                    timestamp: now,
                    coordinate: location.coordinate,
                    altitude: location.altitude,
                    locationName: reverseGeocodedName,
                    recordType: type,
                    timeFrame: timeFrame
                )
                setRecord(type: type, timeFrame: timeFrame, record: newRecord)
                RecordHistoryManager.shared.addRecord(recordType: type, detail: newRecord)

                // Photo prompts only for all-time records
                if timeFrame == .allTime {
                    promptForPhoto(recordType: type, detail: newRecord)
                }

                // Check notification settings based on timeframe
                let shouldNotify: Bool
                switch timeFrame {
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
            }
        } else {
            // Set initial record for this timeframe
            debugLog("Setting initial \(type) (\(timeFrame.rawValue)) to \(newValue)")
            let newRecord = RecordDetail(
                value: newValue,
                timestamp: now,
                coordinate: location.coordinate,
                altitude: location.altitude,
                locationName: reverseGeocodedName,
                recordType: type,
                timeFrame: timeFrame
            )
            setRecord(type: type, timeFrame: timeFrame, record: newRecord)
            RecordHistoryManager.shared.addRecord(recordType: type, detail: newRecord)
            // Don't prompt for photos or send notifications for initial records
        }
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
            debugLog("📍 Using cached location for (\(lat), \(lon)): \(cachedName)")
            return cachedName
        }

        // Check if geocoding is already in progress
        if isGeocodingInProgress {
            debugLog("Geocoding already in progress, skipping request")
            return ""
        }

        // Throttle geocoding to avoid rate limits
        let now = Date()
        if let lastTime = lastGeocodingTime, now.timeIntervalSince(lastTime) < geocodingThrottleInterval {
            debugLog("Throttling geocoding request")
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

                defer {
                    Task { @MainActor in
                        self.isGeocodingInProgress = false
                    }
                }

                var name: String? = nil

                if let error = error {
                    debugLog("Geocoding error: \(error.localizedDescription)")
                    Task { @MainActor in
                        self.consecutiveGeocodingFailures += 1
                        if self.hasGeocodingIssues {
                            debugLog("⚠️ Multiple geocoding failures detected (\(self.consecutiveGeocodingFailures))")
                        }
                    }
                } else if let placemark = placemarks?.first {
                    // Reset failure counter on success
                    Task { @MainActor in
                        self.consecutiveGeocodingFailures = 0
                    }

                    if let city = placemark.locality, let country = placemark.country {
                        name = "\(city), \(country)"
                    } else if let placemarkName = placemark.name {
                        name = placemarkName
                    }

                    // Store in cache if successful
                    if let name = name {
                        Task {
                            await sharedGeocodingCache.setCachedName(name, for: location.coordinate)
                            debugLog("💾 Cached location for (\(lat), \(lon)): \(name)")
                        }
                    }
                }

                continuation.resume(returning: name)
            }
        }
    }

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

        // Skip "Null Island" locations (0,0 with ~0 altitude) - these are placeholder values
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let alt = location.altitude
        let isNullIsland = abs(lat) < 0.01 && abs(lon) < 0.01 && abs(alt) < 1.0
        if isNullIsland {
            debugLog("⚠️ Skipping Null Island location - invalid GPS data")
            return
        }

        // Skip unrealistic altitudes (likely airplane or bad GPS data)
        // Mount Everest is 8,849m - anything above 9,000m is not a ground location
        let maxRealisticAltitude: Double = 9000.0  // meters
        if alt > maxRealisticAltitude {
            debugLog("⚠️ Skipping unrealistic altitude (\(Int(alt))m) - likely airplane or bad GPS")
            return
        }

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

        // Record this location for daily statistics (used for graphs)
        let settings = SettingsManager.shared
        DailyStatisticManager.shared.recordLocation(location, homeCoordinate: settings.homeCoordinate)

        let latDelta = settings.minLatitudeDelta
        let lonDelta = settings.minLongitudeDelta
        let altDeltaMeters = settings.minAltitudeDeltaMeters
        let distanceDeltaMeters = settings.minDistanceDeltaMeters

        let distanceMeters = distanceFromHome(location: location, settings: settings)

        debugLog(">> updateRecords called")
        debugLog("Location: lat=\(lat), lon=\(lon), alt=\(alt)")

        // Check all timeframes for each record type
        for timeFrame in TimeFrame.allCases {
            // Furthest North (higher latitude is better)
            checkAndUpdateRecord(
                type: "Furthest North",
                newValue: lat,
                threshold: latDelta,
                compareAscending: false,
                location: location,
                reverseGeocodedName: reverseGeocodedName,
                timeFrame: timeFrame
            )

            // Furthest South (lower latitude is better)
            checkAndUpdateRecord(
                type: "Furthest South",
                newValue: lat,
                threshold: latDelta,
                compareAscending: true,
                location: location,
                reverseGeocodedName: reverseGeocodedName,
                timeFrame: timeFrame
            )

            // Furthest East (higher longitude is better)
            checkAndUpdateRecord(
                type: "Furthest East",
                newValue: lon,
                threshold: lonDelta,
                compareAscending: false,
                location: location,
                reverseGeocodedName: reverseGeocodedName,
                timeFrame: timeFrame
            )

            // Furthest West (lower longitude is better)
            checkAndUpdateRecord(
                type: "Furthest West",
                newValue: lon,
                threshold: lonDelta,
                compareAscending: true,
                location: location,
                reverseGeocodedName: reverseGeocodedName,
                timeFrame: timeFrame
            )

            // Furthest Up (higher altitude is better)
            checkAndUpdateRecord(
                type: "Furthest Up",
                newValue: alt,
                threshold: altDeltaMeters,
                compareAscending: false,
                location: location,
                reverseGeocodedName: reverseGeocodedName,
                timeFrame: timeFrame
            )

            // Furthest Down (lower altitude is better)
            checkAndUpdateRecord(
                type: "Furthest Down",
                newValue: alt,
                threshold: altDeltaMeters,
                compareAscending: true,
                location: location,
                reverseGeocodedName: reverseGeocodedName,
                timeFrame: timeFrame
            )

            // Furthest from Home (greater distance is better)
            if let distance = distanceMeters {
                checkAndUpdateRecord(
                    type: "Furthest from Home",
                    newValue: distance,  // Store in meters (consistent with altitude)
                    threshold: distanceDeltaMeters,
                    compareAscending: false,
                    location: location,
                    reverseGeocodedName: reverseGeocodedName,
                    timeFrame: timeFrame
                )
            }
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
        let content = UNMutableNotificationContent()

        // Use shared formatting logic
        let formattedValue = detail.formattedValue(unitSystem: SettingsManager.shared.unitSystem)

        // Updated notification: Split text into title and body for better wrapping.
        content.title = "You've set a new \(recordType) record"
        content.body = "(\(formattedValue))"
        content.sound = .default
        
        content.userInfo = ["recordType": recordType]

        let request = UNNotificationRequest(identifier: NotificationIdentifier.newRecord(type: recordType), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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
    private func promptForPhoto(recordType: String, detail: RecordDetail) {
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
}
