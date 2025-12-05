import Foundation
import CoreLocation
import UserNotifications
import CoreData

// MARK: - Geocoding Cache for Record Manager
private actor RecordManagerGeocodingCache {
    private var cache: [String: String] = [:]

    func getCachedLocation(latitude: Double, longitude: Double) -> String? {
        let key = cacheKey(latitude: latitude, longitude: longitude)
        return cache[key]
    }

    func setCachedLocation(latitude: Double, longitude: Double, name: String) {
        let key = cacheKey(latitude: latitude, longitude: longitude)
        cache[key] = name
    }

    private func cacheKey(latitude: Double, longitude: Double) -> String {
        // Round to 4 decimal places (~11 meters precision)
        let roundedLat = round(latitude * 10000) / 10000
        let roundedLon = round(longitude * 10000) / 10000
        return "\(roundedLat),\(roundedLon)"
    }
}

// Global cache instance for record manager
private let recordManagerGeocodingCache = RecordManagerGeocodingCache()

// MARK: - Models

/// Time frame for records
enum TimeFrame: String, CaseIterable {
    case month = "Monthly"
    case year = "Yearly"
    case allTime = "All Time"
}

/// In-memory model for a record event.
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

    /// Initialize with coordinate validation
    init(id: UUID = UUID(), value: Double, timestamp: Date, coordinate: CLLocationCoordinate2D, altitude: Double, locationName: String?, recordType: String, timeFrame: TimeFrame = .allTime, photoData: Data? = nil) {
        self.id = id
        self.value = value
        self.timestamp = timestamp
        self.altitude = altitude
        self.locationName = locationName
        self.recordType = recordType
        self.timeFrame = timeFrame
        self.photoData = photoData

        // Validate coordinate or use a safe default
        if CLLocationCoordinate2DIsValid(coordinate) {
            self.coordinate = coordinate
        } else {
            debugLog("⚠️ Invalid coordinate detected: lat=\(coordinate.latitude), lon=\(coordinate.longitude). Using default.")
            self.coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
    }

    /// Formats the value based on record type and unit system
    func formattedValue(unitSystem: UnitSystem) -> String {
        return FormatUtils.formatValue(value: value, recordType: recordType, unitSystem: unitSystem)
    }
}

@MainActor
class RecordManager: NSObject, ObservableObject {
    static let shared = RecordManager()

    // Monthly records
    @Published var furthestNorthMonth: RecordDetail?
    @Published var furthestSouthMonth: RecordDetail?
    @Published var furthestEastMonth: RecordDetail?
    @Published var furthestWestMonth: RecordDetail?
    @Published var furthestUpMonth: RecordDetail?
    @Published var furthestDownMonth: RecordDetail?
    @Published var furthestFromHomeMonth: RecordDetail?

    // Yearly records
    @Published var furthestNorthYear: RecordDetail?
    @Published var furthestSouthYear: RecordDetail?
    @Published var furthestEastYear: RecordDetail?
    @Published var furthestWestYear: RecordDetail?
    @Published var furthestUpYear: RecordDetail?
    @Published var furthestDownYear: RecordDetail?
    @Published var furthestFromHomeYear: RecordDetail?

    // All-time records
    @Published var furthestNorthAllTime: RecordDetail?
    @Published var furthestSouthAllTime: RecordDetail?
    @Published var furthestEastAllTime: RecordDetail?
    @Published var furthestWestAllTime: RecordDetail?
    @Published var furthestUpAllTime: RecordDetail?
    @Published var furthestDownAllTime: RecordDetail?
    @Published var furthestFromHomeAllTime: RecordDetail?

    // Photo prompt state
    @Published var showPhotoPrompt = false
    @Published var pendingRecordForPhoto: (type: String, detail: RecordDetail)?

    // Reusable geocoder instance to prevent memory leaks
    private let geocoder = CLGeocoder()
    private var lastGeocodingTime: Date?
    private let geocodingThrottleInterval: TimeInterval = 60  // Minimum 60s between geocoding requests
    private var isGeocodingInProgress = false  // Prevent concurrent geocoding requests

    // Serialization for record updates
    private var isUpdatingRecords = false
    private var pendingLocationUpdate: CLLocation?

    // Suppress notifications temporarily after photo import
    private var suppressNotificationsUntil: Date?

    // Block all alerts during photo import (stronger than suppression)
    private var blockAllAlertsDuringImport = false

    override init() {
        super.init()
        loadRecordsFromHistory()
    }

    // MARK: - Helper Methods for Record Access

    /// Get a record by type and timeframe
    func getRecord(type: String, timeFrame: TimeFrame) -> RecordDetail? {
        switch (type, timeFrame) {
        case ("Furthest North", .month): return furthestNorthMonth
        case ("Furthest North", .year): return furthestNorthYear
        case ("Furthest North", .allTime): return furthestNorthAllTime
        case ("Furthest South", .month): return furthestSouthMonth
        case ("Furthest South", .year): return furthestSouthYear
        case ("Furthest South", .allTime): return furthestSouthAllTime
        case ("Furthest East", .month): return furthestEastMonth
        case ("Furthest East", .year): return furthestEastYear
        case ("Furthest East", .allTime): return furthestEastAllTime
        case ("Furthest West", .month): return furthestWestMonth
        case ("Furthest West", .year): return furthestWestYear
        case ("Furthest West", .allTime): return furthestWestAllTime
        case ("Furthest Up", .month): return furthestUpMonth
        case ("Furthest Up", .year): return furthestUpYear
        case ("Furthest Up", .allTime): return furthestUpAllTime
        case ("Furthest Down", .month): return furthestDownMonth
        case ("Furthest Down", .year): return furthestDownYear
        case ("Furthest Down", .allTime): return furthestDownAllTime
        case ("Furthest from Home", .month): return furthestFromHomeMonth
        case ("Furthest from Home", .year): return furthestFromHomeYear
        case ("Furthest from Home", .allTime): return furthestFromHomeAllTime
        default: return nil
        }
    }

    /// Set a record by type and timeframe
    func setRecord(type: String, timeFrame: TimeFrame, record: RecordDetail?) {
        switch (type, timeFrame) {
        case ("Furthest North", .month): furthestNorthMonth = record
        case ("Furthest North", .year): furthestNorthYear = record
        case ("Furthest North", .allTime): furthestNorthAllTime = record
        case ("Furthest South", .month): furthestSouthMonth = record
        case ("Furthest South", .year): furthestSouthYear = record
        case ("Furthest South", .allTime): furthestSouthAllTime = record
        case ("Furthest East", .month): furthestEastMonth = record
        case ("Furthest East", .year): furthestEastYear = record
        case ("Furthest East", .allTime): furthestEastAllTime = record
        case ("Furthest West", .month): furthestWestMonth = record
        case ("Furthest West", .year): furthestWestYear = record
        case ("Furthest West", .allTime): furthestWestAllTime = record
        case ("Furthest Up", .month): furthestUpMonth = record
        case ("Furthest Up", .year): furthestUpYear = record
        case ("Furthest Up", .allTime): furthestUpAllTime = record
        case ("Furthest Down", .month): furthestDownMonth = record
        case ("Furthest Down", .year): furthestDownYear = record
        case ("Furthest Down", .allTime): furthestDownAllTime = record
        case ("Furthest from Home", .month): furthestFromHomeMonth = record
        case ("Furthest from Home", .year): furthestFromHomeYear = record
        case ("Furthest from Home", .allTime): furthestFromHomeAllTime = record
        default: break
        }
    }

    /// Block all alerts during photo import
    func blockAlertsDuringImport(block: Bool) {
        blockAllAlertsDuringImport = block
    }

    /// Call this after importing photos to suppress notifications for a period
    func suppressNotificationsAfterImport(durationSeconds: TimeInterval = 60) {
        suppressNotificationsUntil = Date().addingTimeInterval(durationSeconds)
    }

    private var shouldSuppressNotifications: Bool {
        // Hard block during import takes precedence
        if blockAllAlertsDuringImport {
            return true
        }

        if let suppressUntil = suppressNotificationsUntil {
            if Date() < suppressUntil {
                return true
            } else {
                // Clear the suppression flag once expired
                suppressNotificationsUntil = nil
                return false
            }
        }
        return false
    }
    
    // MARK: - Load Records from Core Data
    func loadRecordsFromHistory() {
        let context = PersistenceController.shared.container.viewContext

        // Single batch fetch to get all record types at once
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        do {
            // Fetch all entries
            let allEntries = try context.fetch(request)

            // Get current month and year boundaries
            let calendar = Calendar.current
            let now = Date()
            let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
            let startOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now

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
        guard let timestamp = entry.timestamp else { return nil }

        return RecordDetail(
            id: entry.id ?? UUID(),
            value: entry.value,
            timestamp: timestamp,
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? "Unknown",
            photoData: entry.photoData
        )
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

            #if DEBUG
            debugLog("\(type) (\(timeFrame.rawValue)): new=\(newValue), current=\(current.value), delta=\(delta)")
            #endif

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

    func updateRecords(with location: CLLocation, reverseGeocodedName: String? = nil) {
        // Serialize updates to prevent race conditions
        if isUpdatingRecords {
            pendingLocationUpdate = location
            return
        }

        isUpdatingRecords = true
        defer {
            isUpdatingRecords = false
            // Process pending update if any
            if let pending = pendingLocationUpdate {
                pendingLocationUpdate = nil
                updateRecords(with: pending, reverseGeocodedName: reverseGeocodedName)
            }
        }

        if reverseGeocodedName == nil {
            let lat = location.coordinate.latitude
            let lon = location.coordinate.longitude

            // Check cache first
            Task {
                if let cachedName = await recordManagerGeocodingCache.getCachedLocation(latitude: lat, longitude: lon) {
                    debugLog("📍 Using cached location for (\(lat), \(lon)): \(cachedName)")
                    await MainActor.run {
                        self.updateRecords(with: location, reverseGeocodedName: cachedName)
                    }
                    return
                }

                // Not in cache, check if geocoding is already in progress
                if await MainActor.run(body: { self.isGeocodingInProgress }) {
                    debugLog("Geocoding already in progress, skipping request")
                    await MainActor.run {
                        self.updateRecords(with: location, reverseGeocodedName: "")
                    }
                    return
                }

                // Throttle geocoding to avoid rate limits and resource exhaustion
                let now = Date()
                let shouldThrottle = await MainActor.run {
                    if let lastTime = self.lastGeocodingTime, now.timeIntervalSince(lastTime) < self.geocodingThrottleInterval {
                        return true
                    }
                    return false
                }

                if shouldThrottle {
                    // Skip geocoding, proceed with empty location name
                    debugLog("Throttling geocoding request")
                    await MainActor.run {
                        self.updateRecords(with: location, reverseGeocodedName: "")
                    }
                    return
                }

                // Cancel any pending geocoding requests
                await MainActor.run {
                    if self.geocoder.isGeocoding {
                        self.geocoder.cancelGeocode()
                    }
                    self.lastGeocodingTime = now
                    self.isGeocodingInProgress = true
                }

                // Perform geocoding
                debugLog("🌐 Geocoding location (\(lat), \(lon))")
                let geocoder = await MainActor.run { self.geocoder }

                geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
                    guard let self = self else { return }

                    defer {
                        Task { @MainActor in
                            self.isGeocodingInProgress = false
                        }
                    }

                    var name: String? = nil

                    if let error = error {
                        debugLog("Geocoding error: \(error.localizedDescription)")
                        // Continue with nil name rather than failing
                    } else if let placemark = placemarks?.first {
                        if let city = placemark.locality, let country = placemark.country {
                            name = "\(city), \(country)"
                        } else if let placemarkName = placemark.name {
                            name = placemarkName
                        }

                        // Store in cache if successful
                        if let name = name {
                            Task {
                                await recordManagerGeocodingCache.setCachedLocation(latitude: lat, longitude: lon, name: name)
                                debugLog("💾 Cached location for (\(lat), \(lon)): \(name)")
                            }
                        }
                    }

                    Task { @MainActor in
                        self.updateRecords(with: location, reverseGeocodedName: name)
                    }
                }
            }
            return
        }
        
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let alt = location.altitude
        let settings = SettingsManager.shared

        let latDelta = settings.minLatitudeDelta
        let lonDelta = settings.minLongitudeDelta
        let altDeltaMeters = settings.minAltitudeDeltaMeters
        let distanceDeltaMeters = settings.minDistanceDeltaMeters

        let distanceMeters = distanceFromHome(location: location, settings: settings)

        #if DEBUG
        debugLog(">> updateRecords called")
        debugLog("Location: lat=\(lat), lon=\(lon), alt=\(alt)")
        #endif

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
                let distFeet = distance * 3.28084  // Store in feet for consistency
                checkAndUpdateRecord(
                    type: "Furthest from Home",
                    newValue: distFeet,
                    threshold: distanceDeltaMeters * 3.28084,  // Convert to feet
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
        let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
        return location.distance(from: homeLocation) // in meters
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
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    // MARK: - Photo Attachment
    func attachPhotoToRecord(recordType: String, photoData: Data?) {
        // Only all-time records can have photos (since we only prompt for all-time records)
        // Find the matching all-time record and update it with photo data
        var updatedRecord: RecordDetail?

        switch recordType {
        case "Furthest North":
            if var record = furthestNorthAllTime {
                record.photoData = photoData
                furthestNorthAllTime = record
                updatedRecord = record
            }
        case "Furthest South":
            if var record = furthestSouthAllTime {
                record.photoData = photoData
                furthestSouthAllTime = record
                updatedRecord = record
            }
        case "Furthest East":
            if var record = furthestEastAllTime {
                record.photoData = photoData
                furthestEastAllTime = record
                updatedRecord = record
            }
        case "Furthest West":
            if var record = furthestWestAllTime {
                record.photoData = photoData
                furthestWestAllTime = record
                updatedRecord = record
            }
        case "Furthest Up":
            if var record = furthestUpAllTime {
                record.photoData = photoData
                furthestUpAllTime = record
                updatedRecord = record
            }
        case "Furthest Down":
            if var record = furthestDownAllTime {
                record.photoData = photoData
                furthestDownAllTime = record
                updatedRecord = record
            }
        case "Furthest from Home":
            if var record = furthestFromHomeAllTime {
                record.photoData = photoData
                furthestFromHomeAllTime = record
                updatedRecord = record
            }
        default:
            break
        }

        // Update Core Data with photo
        if let record = updatedRecord {
            RecordHistoryManager.shared.updateRecordPhoto(recordId: record.id, photoData: photoData)
        }
    }

    // MARK: - Trigger Photo Prompt
    private func promptForPhoto(recordType: String, detail: RecordDetail) {
        // Block during import
        if blockAllAlertsDuringImport {
            return
        }

        // Only prompt if enabled in settings
        guard SettingsManager.shared.photoPromptsEnabled else { return }

        pendingRecordForPhoto = (recordType, detail)
        showPhotoPrompt = true
    }

    // MARK: - Reset In-Memory Records
    func resetRecords() {
        // Reset monthly records
        furthestNorthMonth = nil
        furthestSouthMonth = nil
        furthestEastMonth = nil
        furthestWestMonth = nil
        furthestUpMonth = nil
        furthestDownMonth = nil
        furthestFromHomeMonth = nil

        // Reset yearly records
        furthestNorthYear = nil
        furthestSouthYear = nil
        furthestEastYear = nil
        furthestWestYear = nil
        furthestUpYear = nil
        furthestDownYear = nil
        furthestFromHomeYear = nil

        // Reset all-time records
        furthestNorthAllTime = nil
        furthestSouthAllTime = nil
        furthestEastAllTime = nil
        furthestWestAllTime = nil
        furthestUpAllTime = nil
        furthestDownAllTime = nil
        furthestFromHomeAllTime = nil
    }
}
