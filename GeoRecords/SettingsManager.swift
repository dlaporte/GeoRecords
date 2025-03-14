import Foundation
import Combine
import CoreLocation

/// Choose between Metric or Imperial units.
enum UnitSystem: String, Codable {
    case metric
    case imperial
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    // MARK: - Published Properties
    @Published var notifyOnNewRecord: Bool
    @Published var minLatitudeDelta: Double
    @Published var minLongitudeDelta: Double
    @Published var minAltitudeDeltaFeet: Double
    @Published var timerInterval: TimeInterval
    @Published var homeAddress: String
    @Published var homeCoordinate: CLLocationCoordinate2D?
    @Published var unitSystem: UnitSystem
    
    // MARK: - Default Values
    private let defaultNotifyOnNewRecord = true
    private let defaultMinLatitudeDelta = 1.0
    private let defaultMinLongitudeDelta = 1.0
    private let defaultMinAltitudeDeltaFeet = 500.0
    private let defaultTimerInterval: TimeInterval = 360
    private let defaultHomeAddress = "Your Home Address"
    private let defaultHomeCoordinate: CLLocationCoordinate2D? = nil
    private let defaultUnitSystem: UnitSystem = .imperial
    
    // MARK: - Initialization
    private init() {
        let defaults = UserDefaults.standard
        
        self.notifyOnNewRecord = defaults.object(forKey: "notifyOnNewRecord") as? Bool ?? defaultNotifyOnNewRecord
        self.minLatitudeDelta = defaults.object(forKey: "minLatitudeDelta") as? Double ?? defaultMinLatitudeDelta
        self.minLongitudeDelta = defaults.object(forKey: "minLongitudeDelta") as? Double ?? defaultMinLongitudeDelta
        self.minAltitudeDeltaFeet = defaults.object(forKey: "minAltitudeDeltaFeet") as? Double ?? defaultMinAltitudeDeltaFeet
        self.timerInterval = defaults.object(forKey: "timerInterval") as? Double ?? defaultTimerInterval
        
        self.homeAddress = defaults.string(forKey: "homeAddress") ?? defaultHomeAddress
        if let lat = defaults.object(forKey: "homeLatitude") as? Double,
           let lon = defaults.object(forKey: "homeLongitude") as? Double {
            self.homeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            self.homeCoordinate = defaultHomeCoordinate
        }
        
        if let unitRaw = defaults.string(forKey: "unitSystem"),
           let system = UnitSystem(rawValue: unitRaw) {
            self.unitSystem = system
        } else {
            self.unitSystem = defaultUnitSystem
        }
    }
    
    // MARK: - Persistence
    func saveSettings() {
        let defaults = UserDefaults.standard
        
        defaults.set(notifyOnNewRecord, forKey: "notifyOnNewRecord")
        defaults.set(minLatitudeDelta, forKey: "minLatitudeDelta")
        defaults.set(minLongitudeDelta, forKey: "minLongitudeDelta")
        defaults.set(minAltitudeDeltaFeet, forKey: "minAltitudeDeltaFeet")
        defaults.set(timerInterval, forKey: "timerInterval")
        
        defaults.set(homeAddress, forKey: "homeAddress")
        if let homeCoord = homeCoordinate {
            defaults.set(homeCoord.latitude, forKey: "homeLatitude")
            defaults.set(homeCoord.longitude, forKey: "homeLongitude")
        }
        
        defaults.set(unitSystem.rawValue, forKey: "unitSystem")
    }
    
    func resetToDefaults() {
        notifyOnNewRecord = defaultNotifyOnNewRecord
        minLatitudeDelta = defaultMinLatitudeDelta
        minLongitudeDelta = defaultMinLongitudeDelta
        minAltitudeDeltaFeet = defaultMinAltitudeDeltaFeet
        timerInterval = defaultTimerInterval
        
        homeAddress = defaultHomeAddress
        homeCoordinate = defaultHomeCoordinate
        unitSystem = defaultUnitSystem
        
        saveSettings()
    }
}
