import Foundation
import Combine
import CoreLocation

// UnitSystem enum is now in Constants.swift (shared with widget)

// MARK: - Protocol for Dependency Injection

/// Protocol defining the public interface of SettingsManager for testing and mocking
@MainActor
protocol SettingsManaging: ObservableObject {
    var hasCompletedSetup: Bool { get set }
    var notifyOnMonthlyRecords: Bool { get set }
    var notifyOnYearlyRecords: Bool { get set }
    var notifyOnAllTimeRecords: Bool { get set }
    var summaryNotificationsEnabled: Bool { get set }
    var photoPromptsEnabled: Bool { get set }
    var minLatitudeDelta: Double { get set }
    var minLongitudeDelta: Double { get set }
    var minAltitudeDeltaMeters: Double { get set }
    var minDistanceDeltaMeters: Double { get set }
    var homeAddress: String { get set }
    var homeCoordinate: CLLocationCoordinate2D? { get set }
    var homeLocationName: String? { get set }
    var unitSystem: UnitSystem { get set }

    func saveSettings()
    func resetToDefaults()
}

@MainActor
class SettingsManager: ObservableObject, SettingsManaging {
    static let shared = SettingsManager()

    // MARK: - Published Properties
    @Published var hasCompletedSetup: Bool
    @Published var notifyOnMonthlyRecords: Bool
    @Published var notifyOnYearlyRecords: Bool
    @Published var notifyOnAllTimeRecords: Bool
    @Published var summaryNotificationsEnabled: Bool
    @Published var photoPromptsEnabled: Bool
    @Published var minLatitudeDelta: Double
    @Published var minLongitudeDelta: Double
    @Published var homeAddress: String
    @Published var homeCoordinate: CLLocationCoordinate2D?
    @Published var homeLocationName: String?
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
    private static let defaultNotifyOnMonthlyRecords = false
    private static let defaultNotifyOnYearlyRecords = false
    private static let defaultNotifyOnAllTimeRecords = false  // Set by user in wizard
    private static let defaultSummaryNotificationsEnabled = true  // Set by user in wizard
    private static let defaultPhotoPromptsEnabled = true
    private static let defaultMinLatitudeDelta = 0.1  // ~7 miles / 11 km
    private static let defaultMinLongitudeDelta = 0.1  // ~7 miles / 11 km

    // Imperial defaults
    private static let defaultMinAltitudeDeltaMetersImperial = 30.48  // 100 feet in meters
    private static let defaultMinDistanceDeltaMetersImperial = metersPerMile  // 1 mile in meters

    // Metric defaults
    private static let defaultMinAltitudeDeltaMetersMetric = 100.0  // 100 meters
    private static let defaultMinDistanceDeltaMetersMetric = metersPerKm  // 1 kilometer in meters

    private static let defaultHomeAddress = "Your Home Address"
    private static let defaultHomeCoordinate: CLLocationCoordinate2D? = nil
    private static let defaultUnitSystem: UnitSystem = .imperial

    // MARK: - Initialization
    private init() {
        // Use App Group UserDefaults so widget can read settings
        let defaults = UserDefaults(suiteName: "group.com.georecords.shared") ?? UserDefaults.standard

        // Load unit system
        let loadedUnitSystem: UnitSystem
        if let unitRaw = defaults.string(forKey: UserDefaultsKey.unitSystem.rawValue),
           let system = UnitSystem(rawValue: unitRaw) {
            loadedUnitSystem = system
        } else {
            loadedUnitSystem = Self.defaultUnitSystem
        }

        // Initialize common properties
        self.hasCompletedSetup = defaults.object(forKey: UserDefaultsKey.hasCompletedSetup.rawValue) as? Bool ?? Self.defaultHasCompletedSetup

        // Load notification settings (migrate old setting if needed)
        if let oldNotifySetting = defaults.object(forKey: UserDefaultsKey.notifyOnNewRecord.rawValue) as? Bool {
            // Migrate from old single setting to new timeframe-based settings
            self.notifyOnMonthlyRecords = false
            self.notifyOnYearlyRecords = false
            self.notifyOnAllTimeRecords = oldNotifySetting
            defaults.removeObject(forKey: UserDefaultsKey.notifyOnNewRecord.rawValue)
        } else {
            self.notifyOnMonthlyRecords = defaults.object(forKey: UserDefaultsKey.notifyOnMonthlyRecords.rawValue) as? Bool ?? Self.defaultNotifyOnMonthlyRecords
            self.notifyOnYearlyRecords = defaults.object(forKey: UserDefaultsKey.notifyOnYearlyRecords.rawValue) as? Bool ?? Self.defaultNotifyOnYearlyRecords
            self.notifyOnAllTimeRecords = defaults.object(forKey: UserDefaultsKey.notifyOnAllTimeRecords.rawValue) as? Bool ?? Self.defaultNotifyOnAllTimeRecords
        }

        self.photoPromptsEnabled = defaults.object(forKey: UserDefaultsKey.photoPromptsEnabled.rawValue) as? Bool ?? Self.defaultPhotoPromptsEnabled

        // Load summary notifications setting (migrate from old separate settings if needed)
        if let oldMonthlySetting = defaults.object(forKey: UserDefaultsKey.monthlySummaryEnabled.rawValue) as? Bool,
           let oldYearlySetting = defaults.object(forKey: UserDefaultsKey.yearlySummaryEnabled.rawValue) as? Bool {
            // Migrate: enable if either was enabled
            self.summaryNotificationsEnabled = oldMonthlySetting || oldYearlySetting
            defaults.removeObject(forKey: UserDefaultsKey.monthlySummaryEnabled.rawValue)
            defaults.removeObject(forKey: UserDefaultsKey.yearlySummaryEnabled.rawValue)
        } else {
            self.summaryNotificationsEnabled = defaults.object(forKey: UserDefaultsKey.summaryNotificationsEnabled.rawValue) as? Bool ?? Self.defaultSummaryNotificationsEnabled
        }
        self.minLatitudeDelta = defaults.object(forKey: UserDefaultsKey.minLatitudeDelta.rawValue) as? Double ?? Self.defaultMinLatitudeDelta
        self.minLongitudeDelta = defaults.object(forKey: UserDefaultsKey.minLongitudeDelta.rawValue) as? Double ?? Self.defaultMinLongitudeDelta
        self.unitSystem = loadedUnitSystem

        // Initialize Imperial-specific settings
        self.minAltitudeDeltaMetersImperial = defaults.object(forKey: UserDefaultsKey.minAltitudeDeltaMetersImperial.rawValue) as? Double ?? Self.defaultMinAltitudeDeltaMetersImperial
        self.minDistanceDeltaMetersImperial = defaults.object(forKey: UserDefaultsKey.minDistanceDeltaMetersImperial.rawValue) as? Double ?? Self.defaultMinDistanceDeltaMetersImperial

        // Initialize Metric-specific settings
        self.minAltitudeDeltaMetersMetric = defaults.object(forKey: UserDefaultsKey.minAltitudeDeltaMetersMetric.rawValue) as? Double ?? Self.defaultMinAltitudeDeltaMetersMetric
        self.minDistanceDeltaMetersMetric = defaults.object(forKey: UserDefaultsKey.minDistanceDeltaMetersMetric.rawValue) as? Double ?? Self.defaultMinDistanceDeltaMetersMetric

        // Migrate old settings if needed
        if let oldValue = defaults.object(forKey: UserDefaultsKey.minAltitudeDeltaMeters.rawValue) as? Double {
            // Migrate to appropriate unit-specific setting based on current unit system
            if loadedUnitSystem == .imperial {
                self.minAltitudeDeltaMetersImperial = oldValue
            } else {
                self.minAltitudeDeltaMetersMetric = oldValue
            }
            defaults.removeObject(forKey: UserDefaultsKey.minAltitudeDeltaMeters.rawValue)
        }

        if let oldValue = defaults.object(forKey: UserDefaultsKey.minDistanceDeltaMeters.rawValue) as? Double {
            if loadedUnitSystem == .imperial {
                self.minDistanceDeltaMetersImperial = oldValue
            } else {
                self.minDistanceDeltaMetersMetric = oldValue
            }
            defaults.removeObject(forKey: UserDefaultsKey.minDistanceDeltaMeters.rawValue)
        }

        self.homeAddress = defaults.string(forKey: UserDefaultsKey.homeAddress.rawValue) ?? Self.defaultHomeAddress

        // Try loading home location from iCloud first, then fall back to UserDefaults
        let ubiquitousStore = NSUbiquitousKeyValueStore.default

        // Load home location name
        if let iCloudName = ubiquitousStore.string(forKey: UserDefaultsKey.homeLocationName.rawValue) {
            self.homeLocationName = iCloudName
            debugLog("☁️ Loaded home location name from iCloud: \(iCloudName)")
        } else {
            self.homeLocationName = defaults.string(forKey: UserDefaultsKey.homeLocationName.rawValue)
        }

        // Load home coordinates
        let lat: Double?
        let lon: Double?

        if let iCloudLat = ubiquitousStore.object(forKey: UserDefaultsKey.homeLatitude.rawValue) as? Double,
           let iCloudLon = ubiquitousStore.object(forKey: UserDefaultsKey.homeLongitude.rawValue) as? Double {
            lat = iCloudLat
            lon = iCloudLon
            debugLog("☁️ Loaded home coordinates from iCloud: (\(iCloudLat), \(iCloudLon))")
        } else {
            lat = defaults.object(forKey: UserDefaultsKey.homeLatitude.rawValue) as? Double
            lon = defaults.object(forKey: UserDefaultsKey.homeLongitude.rawValue) as? Double
        }

        if let lat = lat, let lon = lon {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if CLLocationCoordinate2DIsValid(coord) {
                self.homeCoordinate = coord
            } else {
                debugLog("⚠️ Invalid home coordinate loaded: lat=\(lat), lon=\(lon)")
                self.homeCoordinate = Self.defaultHomeCoordinate
            }
        } else {
            self.homeCoordinate = Self.defaultHomeCoordinate
        }

        // Perform migration cleanup after all properties are initialized
        if defaults.object(forKey: UserDefaultsKey.minAltitudeDeltaFeet.rawValue) != nil {
            defaults.removeObject(forKey: UserDefaultsKey.minAltitudeDeltaFeet.rawValue)
            defaults.set(self.minAltitudeDeltaMeters, forKey: UserDefaultsKey.minAltitudeDeltaMeters.rawValue)
        }
    }
    
    // MARK: - Persistence
    func saveSettings() {
        // Use App Group UserDefaults so widget can read settings
        let defaults = UserDefaults(suiteName: "group.com.georecords.shared") ?? UserDefaults.standard
        let ubiquitousStore = NSUbiquitousKeyValueStore.default

        defaults.set(hasCompletedSetup, forKey: UserDefaultsKey.hasCompletedSetup.rawValue)
        defaults.set(notifyOnMonthlyRecords, forKey: UserDefaultsKey.notifyOnMonthlyRecords.rawValue)
        defaults.set(notifyOnYearlyRecords, forKey: UserDefaultsKey.notifyOnYearlyRecords.rawValue)
        defaults.set(notifyOnAllTimeRecords, forKey: UserDefaultsKey.notifyOnAllTimeRecords.rawValue)
        defaults.set(summaryNotificationsEnabled, forKey: UserDefaultsKey.summaryNotificationsEnabled.rawValue)
        defaults.set(photoPromptsEnabled, forKey: UserDefaultsKey.photoPromptsEnabled.rawValue)
        defaults.set(minLatitudeDelta, forKey: UserDefaultsKey.minLatitudeDelta.rawValue)
        defaults.set(minLongitudeDelta, forKey: UserDefaultsKey.minLongitudeDelta.rawValue)

        // Save both Imperial and Metric settings separately
        defaults.set(minAltitudeDeltaMetersImperial, forKey: UserDefaultsKey.minAltitudeDeltaMetersImperial.rawValue)
        defaults.set(minDistanceDeltaMetersImperial, forKey: UserDefaultsKey.minDistanceDeltaMetersImperial.rawValue)
        defaults.set(minAltitudeDeltaMetersMetric, forKey: UserDefaultsKey.minAltitudeDeltaMetersMetric.rawValue)
        defaults.set(minDistanceDeltaMetersMetric, forKey: UserDefaultsKey.minDistanceDeltaMetersMetric.rawValue)

        defaults.set(homeAddress, forKey: UserDefaultsKey.homeAddress.rawValue)
        if let homeLocationName = homeLocationName {
            defaults.set(homeLocationName, forKey: UserDefaultsKey.homeLocationName.rawValue)
            // Also save to iCloud
            ubiquitousStore.set(homeLocationName, forKey: UserDefaultsKey.homeLocationName.rawValue)
        }
        if let homeCoord = homeCoordinate {
            defaults.set(homeCoord.latitude, forKey: UserDefaultsKey.homeLatitude.rawValue)
            defaults.set(homeCoord.longitude, forKey: UserDefaultsKey.homeLongitude.rawValue)
            // Also save to iCloud
            ubiquitousStore.set(homeCoord.latitude, forKey: UserDefaultsKey.homeLatitude.rawValue)
            ubiquitousStore.set(homeCoord.longitude, forKey: UserDefaultsKey.homeLongitude.rawValue)
        }

        defaults.set(unitSystem.rawValue, forKey: UserDefaultsKey.unitSystem.rawValue)

        // Sync iCloud Key-Value Store
        ubiquitousStore.synchronize()
    }
    
    func resetToDefaults() {
        notifyOnMonthlyRecords = Self.defaultNotifyOnMonthlyRecords
        notifyOnYearlyRecords = Self.defaultNotifyOnYearlyRecords
        notifyOnAllTimeRecords = Self.defaultNotifyOnAllTimeRecords
        summaryNotificationsEnabled = Self.defaultSummaryNotificationsEnabled
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
