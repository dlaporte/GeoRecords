import Foundation
import CoreLocation
import UserNotifications
import CoreData

// MARK: - Models

/// In-memory model for a record event.
struct RecordDetail: Identifiable {
    var id = UUID()
    var value: Double           // For latitude, longitude, altitude, or distance
    var timestamp: Date         // Non-optional Date
    var coordinate: CLLocationCoordinate2D
    var altitude: Double
    var locationName: String?
    var recordType: String
    var photoData: Data?        // JPEG photo data captured when record was set

    /// Initialize with coordinate validation
    init(id: UUID = UUID(), value: Double, timestamp: Date, coordinate: CLLocationCoordinate2D, altitude: Double, locationName: String?, recordType: String, photoData: Data? = nil) {
        self.id = id
        self.value = value
        self.timestamp = timestamp
        self.altitude = altitude
        self.locationName = locationName
        self.recordType = recordType
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

    @Published var furthestNorth: RecordDetail?
    @Published var furthestSouth: RecordDetail?
    @Published var furthestEast: RecordDetail?
    @Published var furthestWest: RecordDetail?
    @Published var furthestUp: RecordDetail?
    @Published var furthestDown: RecordDetail?
    @Published var furthestFromHome: RecordDetail?

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
            // Fetch all entries grouped by recordType
            let allEntries = try context.fetch(request)

            // Group entries by recordType
            let grouped = Dictionary(grouping: allEntries) { entry -> String in
                entry.recordType ?? "Unknown"
            }

            // Helper to find extreme record from group
            func findExtreme(in entries: [RecordHistoryEntry], ascending: Bool) -> RecordHistoryEntry? {
                return entries.sorted { ascending ? $0.value < $1.value : $0.value > $1.value }.first
            }

            // Process each record type
            if let northEntries = grouped["Furthest North"], let entry = findExtreme(in: northEntries, ascending: false) {
                self.furthestNorth = makeRecordDetail(from: entry)
            }

            if let southEntries = grouped["Furthest South"], let entry = findExtreme(in: southEntries, ascending: true) {
                self.furthestSouth = makeRecordDetail(from: entry)
            }

            if let eastEntries = grouped["Furthest East"], let entry = findExtreme(in: eastEntries, ascending: false) {
                self.furthestEast = makeRecordDetail(from: entry)
            }

            if let westEntries = grouped["Furthest West"], let entry = findExtreme(in: westEntries, ascending: true) {
                self.furthestWest = makeRecordDetail(from: entry)
            }

            if let upEntries = grouped["Furthest Up"], let entry = findExtreme(in: upEntries, ascending: false) {
                self.furthestUp = makeRecordDetail(from: entry)
            }

            if let downEntries = grouped["Furthest Down"], let entry = findExtreme(in: downEntries, ascending: true) {
                self.furthestDown = makeRecordDetail(from: entry)
            }

            if let homeEntries = grouped["Furthest from Home"], let entry = findExtreme(in: homeEntries, ascending: false) {
                self.furthestFromHome = makeRecordDetail(from: entry)
            }

            debugLog("Loaded all records from history in single batch fetch")
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
            // Check if geocoding is already in progress
            if isGeocodingInProgress {
                debugLog("Geocoding already in progress, skipping request")
                self.updateRecords(with: location, reverseGeocodedName: "")
                return
            }

            // Throttle geocoding to avoid rate limits and resource exhaustion
            let now = Date()
            if let lastTime = lastGeocodingTime, now.timeIntervalSince(lastTime) < geocodingThrottleInterval {
                // Skip geocoding, proceed with empty location name
                self.updateRecords(with: location, reverseGeocodedName: "")
                return
            }

            // Cancel any pending geocoding requests
            if geocoder.isGeocoding {
                geocoder.cancelGeocode()
            }

            lastGeocodingTime = now
            isGeocodingInProgress = true

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
                }

                Task { @MainActor in
                    self.updateRecords(with: location, reverseGeocodedName: name)
                }
            }
            return
        }
        
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let alt = location.altitude
        let now = Date()
        let settings = SettingsManager.shared
        
        let latDelta = settings.minLatitudeDelta
        let lonDelta = settings.minLongitudeDelta
        let altDeltaMeters = settings.minAltitudeDeltaMeters
        
        let distanceMeters = distanceFromHome(location: location, settings: settings)
        
        #if DEBUG
        debugLog(">> updateRecords called at \(now)")
        debugLog("Location: lat=\(lat), lon=\(lon), alt=\(alt)")
        debugLog("Thresholds: latDelta=\(latDelta), lonDelta=\(lonDelta), altDelta=\(altDeltaMeters) m")
        #endif
        
        // ---------- Furthest North ----------
        if let current = furthestNorth {
            let delta = lat - current.value
            debugLog("Furthest North: new lat=\(lat), current=\(current.value), delta=\(delta)")
            if delta > latDelta {
                let newRecord = RecordDetail(value: lat, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest North")
                furthestNorth = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest North", detail: newRecord)
                promptForPhoto(recordType: "Furthest North", detail: newRecord)
                if settings.notifyOnNewRecord && !shouldSuppressNotifications { sendRecordNotification(recordType: "Furthest North", detail: newRecord) }
            }
        } else {
            debugLog("Setting initial Furthest North to \(lat)")
            let newRecord = RecordDetail(value: lat, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest North")
            furthestNorth = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest North", detail: newRecord)
            // Don't prompt for photos or send notifications for initial records, only for records that beat existing ones
        }
        
        // ---------- Furthest South ----------
        if let current = furthestSouth {
            let delta = current.value - lat
            debugLog("Furthest South: new lat=\(lat), current=\(current.value), delta=\(delta)")
            if delta > latDelta {
                let newRecord = RecordDetail(value: lat, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest South")
                furthestSouth = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest South", detail: newRecord)
                promptForPhoto(recordType: "Furthest South", detail: newRecord)
                if settings.notifyOnNewRecord && !shouldSuppressNotifications { sendRecordNotification(recordType: "Furthest South", detail: newRecord) }
            }
        } else {
            debugLog("Setting initial Furthest South to \(lat)")
            let newRecord = RecordDetail(value: lat, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest South")
            furthestSouth = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest South", detail: newRecord)
            // Don't prompt for photos or send notifications for initial records, only for records that beat existing ones
        }
        
        // ---------- Furthest East ----------
        if let current = furthestEast {
            let delta = lon - current.value
            debugLog("Furthest East: new lon=\(lon), current=\(current.value), delta=\(delta)")
            if delta > lonDelta {
                let newRecord = RecordDetail(value: lon, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest East")
                furthestEast = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest East", detail: newRecord)
                promptForPhoto(recordType: "Furthest East", detail: newRecord)
                if settings.notifyOnNewRecord && !shouldSuppressNotifications { sendRecordNotification(recordType: "Furthest East", detail: newRecord) }
            }
        } else {
            debugLog("Setting initial Furthest East to \(lon)")
            let newRecord = RecordDetail(value: lon, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest East")
            furthestEast = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest East", detail: newRecord)
            // Don't prompt for photos or send notifications for initial records, only for records that beat existing ones
        }
        
        // ---------- Furthest West ----------
        if let current = furthestWest {
            let delta = current.value - lon
            debugLog("Furthest West: new lon=\(lon), current=\(current.value), delta=\(delta)")
            if delta > lonDelta {
                let newRecord = RecordDetail(value: lon, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest West")
                furthestWest = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest West", detail: newRecord)
                promptForPhoto(recordType: "Furthest West", detail: newRecord)
                if settings.notifyOnNewRecord && !shouldSuppressNotifications { sendRecordNotification(recordType: "Furthest West", detail: newRecord) }
            }
        } else {
            debugLog("Setting initial Furthest West to \(lon)")
            let newRecord = RecordDetail(value: lon, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest West")
            furthestWest = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest West", detail: newRecord)
            // Don't prompt for photos or send notifications for initial records, only for records that beat existing ones
        }
        
        // ---------- Furthest Up (Altitude High) ----------
        // Always store altitude in meters (canonical), compare in meters
        if let current = furthestUp {
            let delta = alt - current.value  // Both in meters
            debugLog("Furthest Up: new alt=\(alt)m, current=\(current.value)m, delta=\(delta)m")
            if delta > altDeltaMeters {
                let newRecord = RecordDetail(value: alt, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest Up")
                furthestUp = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest Up", detail: newRecord)
                promptForPhoto(recordType: "Furthest Up", detail: newRecord)
                debugLog("NEW RECORD: Furthest Up updated to \(alt)m")
                if settings.notifyOnNewRecord && !shouldSuppressNotifications { sendRecordNotification(recordType: "Furthest Up", detail: newRecord) }
            }
        } else {
            debugLog("Setting initial Furthest Up to \(alt)m")
            let newRecord = RecordDetail(value: alt, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest Up")
            furthestUp = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest Up", detail: newRecord)
            // Don't prompt for photos or send notifications for initial records, only for records that beat existing ones
        }

        // ---------- Furthest Down (Altitude Low) ----------
        // Always store altitude in meters (canonical), compare in meters
        if let current = furthestDown {
            let delta = current.value - alt  // Both in meters
            debugLog("Furthest Down: new alt=\(alt)m, current=\(current.value)m, delta=\(delta)m")
            if delta > altDeltaMeters {
                let newRecord = RecordDetail(value: alt, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest Down")
                furthestDown = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest Down", detail: newRecord)
                promptForPhoto(recordType: "Furthest Down", detail: newRecord)
                debugLog("NEW RECORD: Furthest Down updated to \(alt)m")
                if settings.notifyOnNewRecord && !shouldSuppressNotifications { sendRecordNotification(recordType: "Furthest Down", detail: newRecord) }
            }
        } else {
            debugLog("Setting initial Furthest Down to \(alt)m")
            let newRecord = RecordDetail(value: alt, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest Down")
            furthestDown = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest Down", detail: newRecord)
            // Don't prompt for photos or send notifications for initial records, only for records that beat existing ones
        }
        
        // ---------- Furthest from Home ----------
        if let distance = distanceMeters {
            let distFeet = distance * 3.28084  // Canonical value stored in feet.
            let distanceDeltaMeters = settings.minDistanceDeltaMeters
            if let current = furthestFromHome {
                let currentDistanceMeters = current.value / 3.28084
                let delta = distance - currentDistanceMeters  // Compare in meters
                debugLog("Furthest from Home: new distance=\(distance)m, current=\(currentDistanceMeters)m, delta=\(delta)m")
                if delta > distanceDeltaMeters {
                    let newRecord = RecordDetail(value: distFeet,
                                                 timestamp: now,
                                                 coordinate: location.coordinate,
                                                 altitude: alt,
                                                 locationName: reverseGeocodedName,
                                                 recordType: "Furthest from Home")
                    furthestFromHome = newRecord
                    RecordHistoryManager.shared.addRecord(recordType: "Furthest from Home", detail: newRecord)
                    promptForPhoto(recordType: "Furthest from Home", detail: newRecord)
                    debugLog("NEW RECORD: Furthest from Home updated to \(distance)m (\(distFeet) ft)")
                    if settings.notifyOnNewRecord && !shouldSuppressNotifications { sendRecordNotification(recordType: "Furthest from Home", detail: newRecord) }
                }
            } else {
                debugLog("Setting initial Furthest from Home to \(distFeet) ft")
                let newRecord = RecordDetail(value: distFeet,
                                             timestamp: now,
                                             coordinate: location.coordinate,
                                             altitude: alt,
                                             locationName: reverseGeocodedName,
                                             recordType: "Furthest from Home")
                furthestFromHome = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest from Home", detail: newRecord)
                // Don't prompt for photos or send notifications for initial records, only for records that beat existing ones
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
        // Find the matching record and update it with photo data
        var updatedRecord: RecordDetail?

        switch recordType {
        case "Furthest North":
            if var record = furthestNorth {
                record.photoData = photoData
                furthestNorth = record
                updatedRecord = record
            }
        case "Furthest South":
            if var record = furthestSouth {
                record.photoData = photoData
                furthestSouth = record
                updatedRecord = record
            }
        case "Furthest East":
            if var record = furthestEast {
                record.photoData = photoData
                furthestEast = record
                updatedRecord = record
            }
        case "Furthest West":
            if var record = furthestWest {
                record.photoData = photoData
                furthestWest = record
                updatedRecord = record
            }
        case "Furthest Up":
            if var record = furthestUp {
                record.photoData = photoData
                furthestUp = record
                updatedRecord = record
            }
        case "Furthest Down":
            if var record = furthestDown {
                record.photoData = photoData
                furthestDown = record
                updatedRecord = record
            }
        case "Furthest from Home":
            if var record = furthestFromHome {
                record.photoData = photoData
                furthestFromHome = record
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
        furthestNorth = nil
        furthestSouth = nil
        furthestEast = nil
        furthestWest = nil
        furthestUp = nil
        furthestDown = nil
        furthestFromHome = nil
    }
}
