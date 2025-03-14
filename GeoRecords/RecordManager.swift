import Foundation
import CoreLocation
import UserNotifications
import CoreData

/// In-memory model for a record event.
struct RecordDetail: Identifiable {
    var id = UUID()
    var value: Double           // For latitude, longitude, altitude, or distance
    var timestamp: Date         // Non-optional Date
    var coordinate: CLLocationCoordinate2D
    var altitude: Double
    var locationName: String?
    var recordType: String
}

class RecordManager: NSObject, ObservableObject {
    static let shared = RecordManager()
    
    @Published var furthestNorth: RecordDetail?
    @Published var furthestSouth: RecordDetail?
    @Published var furthestEast: RecordDetail?
    @Published var furthestWest: RecordDetail?
    @Published var furthestUp: RecordDetail?
    @Published var furthestDown: RecordDetail?
    @Published var furthestFromHome: RecordDetail?
    
    override init() {
        super.init()
        loadRecordsFromHistory()
    }
    
    // MARK: - Load Records from Core Data
    func loadRecordsFromHistory() {
        let context = PersistenceController.shared.container.viewContext
        let types = [
            "Furthest North",
            "Furthest South",
            "Furthest East",
            "Furthest West",
            "Furthest Up",
            "Furthest Down",
            "Furthest from Home"
        ]
        
        for type in types {
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "recordType == %@", type)
            
            switch type {
            case "Furthest North":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: false)]
            case "Furthest South":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: true)]
            case "Furthest East":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: false)]
            case "Furthest West":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: true)]
            case "Furthest Up":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: false)]
            case "Furthest Down":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: true)]
            case "Furthest from Home":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: false)]
            default:
                request.sortDescriptors = []
            }
            
            request.fetchLimit = 1
            
            do {
                let results = try context.fetch(request)
                if let entry = results.first {
                    let detail = RecordDetail(
                        id: entry.id ?? UUID(),
                        value: entry.value,
                        timestamp: entry.timestamp!,
                        coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
                        altitude: entry.altitude,
                        locationName: entry.locationName,
                        recordType: entry.recordType ?? type
                    )
                    
                    switch type {
                    case "Furthest North":   self.furthestNorth = detail
                    case "Furthest South":   self.furthestSouth = detail
                    case "Furthest East":    self.furthestEast  = detail
                    case "Furthest West":    self.furthestWest  = detail
                    case "Furthest Up":      self.furthestUp    = detail
                    case "Furthest Down":    self.furthestDown  = detail
                    case "Furthest from Home": self.furthestFromHome = detail
                    default: break
                    }
                    
                    print("Loaded \(type) record from history: value=\(entry.value)")
                }
            } catch {
                print("Failed to load \(type) record: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Update Records
    func updateRecords(with location: CLLocation, reverseGeocodedName: String? = nil) {
        if reverseGeocodedName == nil {
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
                var name: String? = nil
                if let placemark = placemarks?.first {
                    if let city = placemark.locality, let country = placemark.country {
                        name = "\(city), \(country)"
                    } else if let placemarkName = placemark.name {
                        name = placemarkName
                    }
                }
                DispatchQueue.main.async {
                    self?.updateRecords(with: location, reverseGeocodedName: name)
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
        let altDeltaMeters = settings.minAltitudeDeltaFeet * 0.3048
        
        let distanceMeters = distanceFromHome(location: location, settings: settings)
        
        print(">> updateRecords called at \(now)")
        print("Location: lat=\(lat), lon=\(lon), alt=\(alt)")
        print("Thresholds: latDelta=\(latDelta), lonDelta=\(lonDelta), altDelta=\(altDeltaMeters) m")
        
        // ---------- Furthest North ----------
        if let current = furthestNorth {
            let delta = lat - current.value
            print("Furthest North: new lat=\(lat), current=\(current.value), delta=\(delta)")
            if delta > latDelta {
                let newRecord = RecordDetail(value: lat, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest North")
                furthestNorth = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest North", detail: newRecord)
                if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest North", detail: newRecord) }
            }
        } else {
            print("Setting initial Furthest North to \(lat)")
            let newRecord = RecordDetail(value: lat, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest North")
            furthestNorth = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest North", detail: newRecord)
            if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest North", detail: newRecord) }
        }
        
        // ---------- Furthest South ----------
        if let current = furthestSouth {
            let delta = current.value - lat
            print("Furthest South: new lat=\(lat), current=\(current.value), delta=\(delta)")
            if delta > latDelta {
                let newRecord = RecordDetail(value: lat, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest South")
                furthestSouth = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest South", detail: newRecord)
                if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest South", detail: newRecord) }
            }
        } else {
            print("Setting initial Furthest South to \(lat)")
            let newRecord = RecordDetail(value: lat, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest South")
            furthestSouth = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest South", detail: newRecord)
            if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest South", detail: newRecord) }
        }
        
        // ---------- Furthest East ----------
        if let current = furthestEast {
            let delta = lon - current.value
            print("Furthest East: new lon=\(lon), current=\(current.value), delta=\(delta)")
            if delta > lonDelta {
                let newRecord = RecordDetail(value: lon, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest East")
                furthestEast = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest East", detail: newRecord)
                if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest East", detail: newRecord) }
            }
        } else {
            print("Setting initial Furthest East to \(lon)")
            let newRecord = RecordDetail(value: lon, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest East")
            furthestEast = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest East", detail: newRecord)
            if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest East", detail: newRecord) }
        }
        
        // ---------- Furthest West ----------
        if let current = furthestWest {
            let delta = current.value - lon
            print("Furthest West: new lon=\(lon), current=\(current.value), delta=\(delta)")
            if delta > lonDelta {
                let newRecord = RecordDetail(value: lon, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest West")
                furthestWest = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest West", detail: newRecord)
                if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest West", detail: newRecord) }
            }
        } else {
            print("Setting initial Furthest West to \(lon)")
            let newRecord = RecordDetail(value: lon, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest West")
            furthestWest = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest West", detail: newRecord)
            if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest West", detail: newRecord) }
        }
        
        // ---------- Furthest Up (Altitude High) ----------
        let newAltValue = (settings.unitSystem == .imperial) ? alt * 3.28084 : alt
        if let current = furthestUp {
            let currentAltValue = current.value
            let delta = newAltValue - currentAltValue
            print("Furthest Up: new alt=\(newAltValue), current=\(currentAltValue), delta=\(delta)")
            if delta > (altDeltaMeters * (settings.unitSystem == .imperial ? 3.28084 : 1)) {
                let newRecord = RecordDetail(value: alt, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest Up")
                furthestUp = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest Up", detail: newRecord)
                print("NEW RECORD: Furthest Up updated to \(alt)")
                if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest Up", detail: newRecord) }
            }
        } else {
            print("Setting initial Furthest Up to \(alt)")
            let newRecord = RecordDetail(value: alt, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest Up")
            furthestUp = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest Up", detail: newRecord)
            if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest Up", detail: newRecord) }
        }
        
        // ---------- Furthest Down (Altitude Low) ----------
        if let current = furthestDown {
            let currentAltValue = (settings.unitSystem == .imperial) ? current.value * 3.28084 : current.value
            let newAlt = (settings.unitSystem == .imperial) ? alt * 3.28084 : alt
            let delta = currentAltValue - newAlt
            print("Furthest Down: new alt=\(newAlt), current=\(currentAltValue), delta=\(delta)")
            if delta > (altDeltaMeters * (settings.unitSystem == .imperial ? 3.28084 : 1)) {
                let newRecord = RecordDetail(value: alt, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest Down")
                furthestDown = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest Down", detail: newRecord)
                print("NEW RECORD: Furthest Down updated to \(alt)")
                if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest Down", detail: newRecord) }
            }
        } else {
            print("Setting initial Furthest Down to \(alt)")
            let newRecord = RecordDetail(value: alt, timestamp: now, coordinate: location.coordinate, altitude: alt, locationName: reverseGeocodedName, recordType: "Furthest Down")
            furthestDown = newRecord
            RecordHistoryManager.shared.addRecord(recordType: "Furthest Down", detail: newRecord)
            if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest Down", detail: newRecord) }
        }
        
        // ---------- Furthest from Home ----------
        if let distance = distanceMeters {
            let distFeet = distance * 3.28084  // Canonical value stored in feet.
            if let current = furthestFromHome {
                let delta = distFeet - current.value
                print("Furthest from Home: new distance=\(distFeet) ft, current=\(current.value) ft, delta=\(delta)")
                if delta > 0 {
                    let newRecord = RecordDetail(value: distFeet,
                                                 timestamp: now,
                                                 coordinate: location.coordinate,
                                                 altitude: alt,
                                                 locationName: reverseGeocodedName,
                                                 recordType: "Furthest from Home")
                    furthestFromHome = newRecord
                    RecordHistoryManager.shared.addRecord(recordType: "Furthest from Home", detail: newRecord)
                    print("NEW RECORD: Furthest from Home updated to \(distFeet) ft")
                    if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest from Home", detail: newRecord) }
                }
            } else {
                print("Setting initial Furthest from Home to \(distFeet) ft")
                let newRecord = RecordDetail(value: distFeet,
                                             timestamp: now,
                                             coordinate: location.coordinate,
                                             altitude: alt,
                                             locationName: reverseGeocodedName,
                                             recordType: "Furthest from Home")
                furthestFromHome = newRecord
                RecordHistoryManager.shared.addRecord(recordType: "Furthest from Home", detail: newRecord)
                if settings.notifyOnNewRecord { sendRecordNotification(recordType: "Furthest from Home", detail: newRecord) }
            }
        }
    }
    
    // MARK: - Distance from Home Calculation
    func distanceFromHome(location: CLLocation, settings: SettingsManager) -> Double? {
        guard let homeCoord = settings.homeCoordinate else {
            print("No home coordinate set; cannot compute distance from home.")
            return nil
        }
        let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
        return location.distance(from: homeLocation) // in meters
    }
    
    // MARK: - Send Notification with Deep Link Info
    func sendRecordNotification(recordType: String, detail: RecordDetail) {
        let content = UNMutableNotificationContent()
        
        var formattedValue = ""
        if recordType.contains("North") ||
            recordType.contains("South") ||
            recordType.contains("East") ||
            recordType.contains("West") {
            formattedValue = String(format: "%.2f°", detail.value)
        } else if recordType.contains("Up") || recordType.contains("Down") {
            let converted = (SettingsManager.shared.unitSystem == .imperial) ? detail.value * 3.28084 : detail.value
            formattedValue = "\(Int(round(converted))) \(SettingsManager.shared.unitSystem == .imperial ? "ft" : "m")"
        } else if recordType == "Furthest from Home" {
            if SettingsManager.shared.unitSystem == .imperial {
                let miles = detail.value / 5280.0
                formattedValue = String(format: "%.2f mi", miles)
            } else {
                let meters = detail.value / 3.28084
                if meters >= 1000 {
                    let km = meters / 1000.0
                    formattedValue = String(format: "%.2f km", km)
                } else {
                    formattedValue = "\(Int(round(meters))) m"
                }
            }
        } else {
            formattedValue = String(format: "%.6f", detail.value)
        }
        
        // Updated notification: Split text into title and body for better wrapping.
        content.title = "You've set a new \(recordType) record"
        content.body = "(\(formattedValue))"
        content.sound = .default
        
        content.userInfo = ["recordType": recordType]
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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
