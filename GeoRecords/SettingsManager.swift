import Foundation
import Combine
import CoreLocation

/// Choose between Metric or Imperial units.
enum UnitSystem: String, Codable {
    case metric
    case imperial
}

@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    // MARK: - Published Properties
    @Published var hasCompletedSetup: Bool
    @Published var notifyOnNewRecord: Bool
    @Published var photoPromptsEnabled: Bool
    @Published var minLatitudeDelta: Double
    @Published var minLongitudeDelta: Double
    @Published var homeAddress: String
    @Published var homeCoordinate: CLLocationCoordinate2D?
    @Published var unitSystem: UnitSystem

    // Separate settings for Imperial and Metric
    @Published var minAltitudeDeltaMetersImperial: Double  // Stored in meters
    @Published var minDistanceDeltaMetersImperial: Double
    @Published var minAltitudeDeltaMetersMetric: Double
    @Published var minDistanceDeltaMetersMetric: Double

    // Computed properties that return the active values based on current unit system
    var minAltitudeDeltaMeters: Double {
        get { unitSystem == .imperial ? minAltitudeDeltaMetersImperial : minAltitudeDeltaMetersMetric }
        set {
            if unitSystem == .imperial {
                minAltitudeDeltaMetersImperial = newValue
            } else {
                minAltitudeDeltaMetersMetric = newValue
            }
        }
    }

    var minDistanceDeltaMeters: Double {
        get { unitSystem == .imperial ? minDistanceDeltaMetersImperial : minDistanceDeltaMetersMetric }
        set {
            if unitSystem == .imperial {
                minDistanceDeltaMetersImperial = newValue
            } else {
                minDistanceDeltaMetersMetric = newValue
            }
        }
    }

    // MARK: - Default Values
    private static let defaultHasCompletedSetup = false
    private static let defaultNotifyOnNewRecord = true
    private static let defaultPhotoPromptsEnabled = true
    private static let defaultMinLatitudeDelta = 0.1  // ~7 miles / 11 km
    private static let defaultMinLongitudeDelta = 0.1  // ~7 miles / 11 km

    // Imperial defaults
    private static let defaultMinAltitudeDeltaMetersImperial = 30.48  // 100 feet in meters
    private static let defaultMinDistanceDeltaMetersImperial = 1609.344  // 1 mile in meters

    // Metric defaults
    private static let defaultMinAltitudeDeltaMetersMetric = 100.0  // 100 meters
    private static let defaultMinDistanceDeltaMetersMetric = 1000.0  // 1 kilometer in meters

    private static let defaultHomeAddress = "Your Home Address"
    private static let defaultHomeCoordinate: CLLocationCoordinate2D? = nil
    private static let defaultUnitSystem: UnitSystem = .imperial

    // MARK: - Initialization
    private init() {
        let defaults = UserDefaults.standard

        // Load unit system
        let loadedUnitSystem: UnitSystem
        if let unitRaw = defaults.string(forKey: "unitSystem"),
           let system = UnitSystem(rawValue: unitRaw) {
            loadedUnitSystem = system
        } else {
            loadedUnitSystem = Self.defaultUnitSystem
        }

        // Initialize common properties
        self.hasCompletedSetup = defaults.object(forKey: "hasCompletedSetup") as? Bool ?? Self.defaultHasCompletedSetup
        self.notifyOnNewRecord = defaults.object(forKey: "notifyOnNewRecord") as? Bool ?? Self.defaultNotifyOnNewRecord
        self.photoPromptsEnabled = defaults.object(forKey: "photoPromptsEnabled") as? Bool ?? Self.defaultPhotoPromptsEnabled
        self.minLatitudeDelta = defaults.object(forKey: "minLatitudeDelta") as? Double ?? Self.defaultMinLatitudeDelta
        self.minLongitudeDelta = defaults.object(forKey: "minLongitudeDelta") as? Double ?? Self.defaultMinLongitudeDelta
        self.unitSystem = loadedUnitSystem

        // Initialize Imperial-specific settings
        self.minAltitudeDeltaMetersImperial = defaults.object(forKey: "minAltitudeDeltaMetersImperial") as? Double ?? Self.defaultMinAltitudeDeltaMetersImperial
        self.minDistanceDeltaMetersImperial = defaults.object(forKey: "minDistanceDeltaMetersImperial") as? Double ?? Self.defaultMinDistanceDeltaMetersImperial

        // Initialize Metric-specific settings
        self.minAltitudeDeltaMetersMetric = defaults.object(forKey: "minAltitudeDeltaMetersMetric") as? Double ?? Self.defaultMinAltitudeDeltaMetersMetric
        self.minDistanceDeltaMetersMetric = defaults.object(forKey: "minDistanceDeltaMetersMetric") as? Double ?? Self.defaultMinDistanceDeltaMetersMetric

        // Migrate old settings if needed
        if let oldValue = defaults.object(forKey: "minAltitudeDeltaMeters") as? Double {
            // Migrate to appropriate unit-specific setting based on current unit system
            if loadedUnitSystem == .imperial {
                self.minAltitudeDeltaMetersImperial = oldValue
            } else {
                self.minAltitudeDeltaMetersMetric = oldValue
            }
            defaults.removeObject(forKey: "minAltitudeDeltaMeters")
        }

        if let oldValue = defaults.object(forKey: "minDistanceDeltaMeters") as? Double {
            if loadedUnitSystem == .imperial {
                self.minDistanceDeltaMetersImperial = oldValue
            } else {
                self.minDistanceDeltaMetersMetric = oldValue
            }
            defaults.removeObject(forKey: "minDistanceDeltaMeters")
        }

        self.homeAddress = defaults.string(forKey: "homeAddress") ?? Self.defaultHomeAddress
        if let lat = defaults.object(forKey: "homeLatitude") as? Double,
           let lon = defaults.object(forKey: "homeLongitude") as? Double {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if CLLocationCoordinate2DIsValid(coord) {
                self.homeCoordinate = coord
            } else {
                debugLog("⚠️ Invalid home coordinate loaded from UserDefaults: lat=\(lat), lon=\(lon)")
                self.homeCoordinate = Self.defaultHomeCoordinate
            }
        } else {
            self.homeCoordinate = Self.defaultHomeCoordinate
        }

        // Perform migration cleanup after all properties are initialized
        if defaults.object(forKey: "minAltitudeDeltaFeet") != nil {
            defaults.removeObject(forKey: "minAltitudeDeltaFeet")
            defaults.set(self.minAltitudeDeltaMeters, forKey: "minAltitudeDeltaMeters")
        }
    }
    
    // MARK: - Persistence
    func saveSettings() {
        let defaults = UserDefaults.standard

        defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        defaults.set(notifyOnNewRecord, forKey: "notifyOnNewRecord")
        defaults.set(photoPromptsEnabled, forKey: "photoPromptsEnabled")
        defaults.set(minLatitudeDelta, forKey: "minLatitudeDelta")
        defaults.set(minLongitudeDelta, forKey: "minLongitudeDelta")

        // Save both Imperial and Metric settings separately
        defaults.set(minAltitudeDeltaMetersImperial, forKey: "minAltitudeDeltaMetersImperial")
        defaults.set(minDistanceDeltaMetersImperial, forKey: "minDistanceDeltaMetersImperial")
        defaults.set(minAltitudeDeltaMetersMetric, forKey: "minAltitudeDeltaMetersMetric")
        defaults.set(minDistanceDeltaMetersMetric, forKey: "minDistanceDeltaMetersMetric")

        defaults.set(homeAddress, forKey: "homeAddress")
        if let homeCoord = homeCoordinate {
            defaults.set(homeCoord.latitude, forKey: "homeLatitude")
            defaults.set(homeCoord.longitude, forKey: "homeLongitude")
        }

        defaults.set(unitSystem.rawValue, forKey: "unitSystem")
    }
    
    func resetToDefaults() {
        notifyOnNewRecord = Self.defaultNotifyOnNewRecord
        minLatitudeDelta = Self.defaultMinLatitudeDelta
        minLongitudeDelta = Self.defaultMinLongitudeDelta

        // Reset both Imperial and Metric to their respective defaults
        minAltitudeDeltaMetersImperial = Self.defaultMinAltitudeDeltaMetersImperial
        minDistanceDeltaMetersImperial = Self.defaultMinDistanceDeltaMetersImperial
        minAltitudeDeltaMetersMetric = Self.defaultMinAltitudeDeltaMetersMetric
        minDistanceDeltaMetersMetric = Self.defaultMinDistanceDeltaMetersMetric

        homeAddress = Self.defaultHomeAddress
        homeCoordinate = Self.defaultHomeCoordinate
        // Don't reset unitSystem - keep the current selection

        saveSettings()
    }
}
