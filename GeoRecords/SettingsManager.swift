import Foundation
import Combine
import CoreLocation
import UserNotifications

// UnitSystem enum is now in Constants.swift (shared with widget)

// MARK: - Protocol for Dependency Injection

/// Protocol defining the public interface of SettingsManager for testing and mocking
@MainActor
protocol SettingsManaging: ObservableObject {
    var hasCompletedSetup: Bool { get set }
    var notifyOnMonthlyRecords: Bool { get set }
    var notifyOnYearlyRecords: Bool { get set }
    var notifyOnAllTimeRecords: Bool { get set }
    var notifyOnNewRegion: Bool { get set }
    var summaryNotificationsEnabled: Bool { get set }
    var photoPromptsEnabled: Bool { get set }
    var inactivityReminderEnabled: Bool { get set }
    var inactivityReminderDays: Int { get set }
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
    @Published var notifyOnNewRegion: Bool
    @Published var summaryNotificationsEnabled: Bool
    @Published var photoPromptsEnabled: Bool
    @Published var inactivityReminderEnabled: Bool
    @Published var inactivityReminderDays: Int
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
    private static let defaultNotifyOnNewRegion = false  // Off by default
    private static let defaultSummaryNotificationsEnabled = true  // Set by user in wizard
    private static let defaultPhotoPromptsEnabled = true
    private static let defaultInactivityReminderEnabled = false  // Set by wizard based on notification permission
    private static let defaultInactivityReminderDays = 7  // Remind after 7 days of inactivity
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
        let ubiquitousStore = NSUbiquitousKeyValueStore.default

        // Pull latest values from iCloud before loading
        ubiquitousStore.synchronize()
        debugLog("☁️ SettingsManager init - synced iCloud Key-Value Store")

        // Helper to load setting with iCloud priority
        func loadBool(key: UserDefaultsKey, defaultValue: Bool) -> Bool {
            if let iCloudValue = ubiquitousStore.object(forKey: key.rawValue) as? Bool {
                debugLog("☁️ Loaded \(key.rawValue) = \(iCloudValue) from iCloud")
                return iCloudValue
            }
            let localValue = defaults.object(forKey: key.rawValue) as? Bool ?? defaultValue
            debugLog("☁️ Loaded \(key.rawValue) = \(localValue) from local/default")
            return localValue
        }

        func loadDouble(key: UserDefaultsKey, defaultValue: Double) -> Double {
            if let iCloudValue = ubiquitousStore.object(forKey: key.rawValue) as? Double {
                return iCloudValue
            }
            return defaults.object(forKey: key.rawValue) as? Double ?? defaultValue
        }

        func loadInt(key: UserDefaultsKey, defaultValue: Int) -> Int {
            if let iCloudValue = ubiquitousStore.object(forKey: key.rawValue) as? Int {
                return Int(iCloudValue)
            }
            return defaults.object(forKey: key.rawValue) as? Int ?? defaultValue
        }

        func loadString(key: UserDefaultsKey, defaultValue: String) -> String {
            if let iCloudValue = ubiquitousStore.string(forKey: key.rawValue) {
                return iCloudValue
            }
            return defaults.string(forKey: key.rawValue) ?? defaultValue
        }

        // Load unit system (iCloud priority)
        let loadedUnitSystem: UnitSystem
        if let iCloudUnitRaw = ubiquitousStore.string(forKey: UserDefaultsKey.unitSystem.rawValue),
           let system = UnitSystem(rawValue: iCloudUnitRaw) {
            loadedUnitSystem = system
        } else if let unitRaw = defaults.string(forKey: UserDefaultsKey.unitSystem.rawValue),
           let system = UnitSystem(rawValue: unitRaw) {
            loadedUnitSystem = system
        } else {
            loadedUnitSystem = Self.defaultUnitSystem
        }

        // hasCompletedSetup is device-local only (not synced to iCloud)
        // Each device needs its own setup/restore flow
        self.hasCompletedSetup = defaults.object(forKey: UserDefaultsKey.hasCompletedSetup.rawValue) as? Bool ?? Self.defaultHasCompletedSetup

        // Load notification settings (migrate old setting if needed)
        if let oldNotifySetting = defaults.object(forKey: UserDefaultsKey.notifyOnNewRecord.rawValue) as? Bool {
            // Migrate from old single setting to new timeframe-based settings
            self.notifyOnMonthlyRecords = false
            self.notifyOnYearlyRecords = false
            self.notifyOnAllTimeRecords = oldNotifySetting
            defaults.removeObject(forKey: UserDefaultsKey.notifyOnNewRecord.rawValue)
        } else {
            self.notifyOnMonthlyRecords = loadBool(key: .notifyOnMonthlyRecords, defaultValue: Self.defaultNotifyOnMonthlyRecords)
            self.notifyOnYearlyRecords = loadBool(key: .notifyOnYearlyRecords, defaultValue: Self.defaultNotifyOnYearlyRecords)
            self.notifyOnAllTimeRecords = loadBool(key: .notifyOnAllTimeRecords, defaultValue: Self.defaultNotifyOnAllTimeRecords)
        }

        self.notifyOnNewRegion = loadBool(key: .notifyOnNewRegion, defaultValue: Self.defaultNotifyOnNewRegion)
        self.photoPromptsEnabled = loadBool(key: .photoPromptsEnabled, defaultValue: Self.defaultPhotoPromptsEnabled)

        // Load inactivity reminder settings
        self.inactivityReminderEnabled = loadBool(key: .inactivityReminderEnabled, defaultValue: Self.defaultInactivityReminderEnabled)
        self.inactivityReminderDays = loadInt(key: .inactivityReminderDays, defaultValue: Self.defaultInactivityReminderDays)

        // Load summary notifications setting (migrate from old separate settings if needed)
        if let oldMonthlySetting = defaults.object(forKey: UserDefaultsKey.monthlySummaryEnabled.rawValue) as? Bool,
           let oldYearlySetting = defaults.object(forKey: UserDefaultsKey.yearlySummaryEnabled.rawValue) as? Bool {
            // Migrate: enable if either was enabled
            self.summaryNotificationsEnabled = oldMonthlySetting || oldYearlySetting
            defaults.removeObject(forKey: UserDefaultsKey.monthlySummaryEnabled.rawValue)
            defaults.removeObject(forKey: UserDefaultsKey.yearlySummaryEnabled.rawValue)
        } else {
            self.summaryNotificationsEnabled = loadBool(key: .summaryNotificationsEnabled, defaultValue: Self.defaultSummaryNotificationsEnabled)
        }
        self.minLatitudeDelta = loadDouble(key: .minLatitudeDelta, defaultValue: Self.defaultMinLatitudeDelta)
        self.minLongitudeDelta = loadDouble(key: .minLongitudeDelta, defaultValue: Self.defaultMinLongitudeDelta)
        self.unitSystem = loadedUnitSystem

        // Initialize Imperial-specific settings
        self.minAltitudeDeltaMetersImperial = loadDouble(key: .minAltitudeDeltaMetersImperial, defaultValue: Self.defaultMinAltitudeDeltaMetersImperial)
        self.minDistanceDeltaMetersImperial = loadDouble(key: .minDistanceDeltaMetersImperial, defaultValue: Self.defaultMinDistanceDeltaMetersImperial)

        // Initialize Metric-specific settings
        self.minAltitudeDeltaMetersMetric = loadDouble(key: .minAltitudeDeltaMetersMetric, defaultValue: Self.defaultMinAltitudeDeltaMetersMetric)
        self.minDistanceDeltaMetersMetric = loadDouble(key: .minDistanceDeltaMetersMetric, defaultValue: Self.defaultMinDistanceDeltaMetersMetric)

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

        self.homeAddress = loadString(key: .homeAddress, defaultValue: Self.defaultHomeAddress)

        // Load home location name (iCloud priority)
        if let iCloudName = ubiquitousStore.string(forKey: UserDefaultsKey.homeLocationName.rawValue) {
            self.homeLocationName = iCloudName
            debugLog("☁️ Loaded home location name from iCloud: \(iCloudName)")
        } else {
            self.homeLocationName = defaults.string(forKey: UserDefaultsKey.homeLocationName.rawValue)
        }

        // Load home coordinates (iCloud priority)
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

        // Listen for iCloud changes from other devices
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore,
            queue: .main
        ) { [weak self] notification in
            // We're on .main queue, so it's safe to call MainActor-isolated method
            MainActor.assumeIsolated {
                self?.handleiCloudSettingsChange(notification)
            }
        }

        // Start syncing
        ubiquitousStore.synchronize()
        debugLog("☁️ Settings iCloud sync initialized")

        // If any notification settings came from iCloud, request permissions if needed
        requestNotificationPermissionsIfNeeded()
    }

    // MARK: - iCloud Sync
    private func handleiCloudSettingsChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }

        debugLog("☁️ iCloud settings changed (reason: \(changeReason))")

        // Only handle server changes from OTHER devices
        // Do NOT handle InitialSyncChange - it can contain stale data that overwrites
        // settings we just saved (e.g., wizard settings get overwritten by old iCloud data)
        guard changeReason == NSUbiquitousKeyValueStoreServerChange else {
            debugLog("☁️ Ignoring iCloud change (not a server change from another device)")
            return
        }

        let ubiquitousStore = NSUbiquitousKeyValueStore.default

        // Update settings from iCloud
        // Note: hasCompletedSetup is NOT synced - it's device-local
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.notifyOnMonthlyRecords.rawValue) as? Bool {
            notifyOnMonthlyRecords = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.notifyOnYearlyRecords.rawValue) as? Bool {
            notifyOnYearlyRecords = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.notifyOnAllTimeRecords.rawValue) as? Bool {
            notifyOnAllTimeRecords = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.notifyOnNewRegion.rawValue) as? Bool {
            notifyOnNewRegion = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.summaryNotificationsEnabled.rawValue) as? Bool {
            summaryNotificationsEnabled = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.photoPromptsEnabled.rawValue) as? Bool {
            photoPromptsEnabled = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.inactivityReminderEnabled.rawValue) as? Bool {
            inactivityReminderEnabled = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.inactivityReminderDays.rawValue) as? Int {
            inactivityReminderDays = Int(value)
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.minLatitudeDelta.rawValue) as? Double {
            minLatitudeDelta = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.minLongitudeDelta.rawValue) as? Double {
            minLongitudeDelta = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.minAltitudeDeltaMetersImperial.rawValue) as? Double {
            minAltitudeDeltaMetersImperial = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.minDistanceDeltaMetersImperial.rawValue) as? Double {
            minDistanceDeltaMetersImperial = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.minAltitudeDeltaMetersMetric.rawValue) as? Double {
            minAltitudeDeltaMetersMetric = value
        }
        if let value = ubiquitousStore.object(forKey: UserDefaultsKey.minDistanceDeltaMetersMetric.rawValue) as? Double {
            minDistanceDeltaMetersMetric = value
        }
        if let value = ubiquitousStore.string(forKey: UserDefaultsKey.homeAddress.rawValue) {
            homeAddress = value
        }
        if let unitRaw = ubiquitousStore.string(forKey: UserDefaultsKey.unitSystem.rawValue),
           let system = UnitSystem(rawValue: unitRaw) {
            unitSystem = system
        }
        if let name = ubiquitousStore.string(forKey: UserDefaultsKey.homeLocationName.rawValue) {
            homeLocationName = name
        }
        if let lat = ubiquitousStore.object(forKey: UserDefaultsKey.homeLatitude.rawValue) as? Double,
           let lon = ubiquitousStore.object(forKey: UserDefaultsKey.homeLongitude.rawValue) as? Double {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if CLLocationCoordinate2DIsValid(coord) {
                homeCoordinate = coord
            }
        }

        debugLog("☁️ Settings updated from iCloud")

        // Also update local UserDefaults to keep them in sync
        saveToUserDefaults()

        // If notifications were enabled from another device, request permissions if needed
        requestNotificationPermissionsIfNeeded()
    }

    /// Save settings to local UserDefaults only (without triggering iCloud sync)
    private func saveToUserDefaults() {
        let defaults = UserDefaults(suiteName: "group.com.georecords.shared") ?? UserDefaults.standard

        defaults.set(hasCompletedSetup, forKey: UserDefaultsKey.hasCompletedSetup.rawValue)
        defaults.set(notifyOnMonthlyRecords, forKey: UserDefaultsKey.notifyOnMonthlyRecords.rawValue)
        defaults.set(notifyOnYearlyRecords, forKey: UserDefaultsKey.notifyOnYearlyRecords.rawValue)
        defaults.set(notifyOnAllTimeRecords, forKey: UserDefaultsKey.notifyOnAllTimeRecords.rawValue)
        defaults.set(notifyOnNewRegion, forKey: UserDefaultsKey.notifyOnNewRegion.rawValue)
        defaults.set(summaryNotificationsEnabled, forKey: UserDefaultsKey.summaryNotificationsEnabled.rawValue)
        defaults.set(photoPromptsEnabled, forKey: UserDefaultsKey.photoPromptsEnabled.rawValue)
        defaults.set(inactivityReminderEnabled, forKey: UserDefaultsKey.inactivityReminderEnabled.rawValue)
        defaults.set(inactivityReminderDays, forKey: UserDefaultsKey.inactivityReminderDays.rawValue)
        defaults.set(minLatitudeDelta, forKey: UserDefaultsKey.minLatitudeDelta.rawValue)
        defaults.set(minLongitudeDelta, forKey: UserDefaultsKey.minLongitudeDelta.rawValue)
        defaults.set(minAltitudeDeltaMetersImperial, forKey: UserDefaultsKey.minAltitudeDeltaMetersImperial.rawValue)
        defaults.set(minDistanceDeltaMetersImperial, forKey: UserDefaultsKey.minDistanceDeltaMetersImperial.rawValue)
        defaults.set(minAltitudeDeltaMetersMetric, forKey: UserDefaultsKey.minAltitudeDeltaMetersMetric.rawValue)
        defaults.set(minDistanceDeltaMetersMetric, forKey: UserDefaultsKey.minDistanceDeltaMetersMetric.rawValue)
        defaults.set(homeAddress, forKey: UserDefaultsKey.homeAddress.rawValue)
        if let homeLocationName = homeLocationName {
            defaults.set(homeLocationName, forKey: UserDefaultsKey.homeLocationName.rawValue)
        }
        if let homeCoord = homeCoordinate {
            defaults.set(homeCoord.latitude, forKey: UserDefaultsKey.homeLatitude.rawValue)
            defaults.set(homeCoord.longitude, forKey: UserDefaultsKey.homeLongitude.rawValue)
        }
        defaults.set(unitSystem.rawValue, forKey: UserDefaultsKey.unitSystem.rawValue)
    }
    
    // MARK: - Persistence
    func saveSettings() {
        // Save to local UserDefaults (for widget and offline access)
        saveToUserDefaults()

        // Save all settings to iCloud
        // Note: hasCompletedSetup is NOT synced - it's device-local
        let ubiquitousStore = NSUbiquitousKeyValueStore.default

        ubiquitousStore.set(notifyOnMonthlyRecords, forKey: UserDefaultsKey.notifyOnMonthlyRecords.rawValue)
        ubiquitousStore.set(notifyOnYearlyRecords, forKey: UserDefaultsKey.notifyOnYearlyRecords.rawValue)
        ubiquitousStore.set(notifyOnAllTimeRecords, forKey: UserDefaultsKey.notifyOnAllTimeRecords.rawValue)
        ubiquitousStore.set(notifyOnNewRegion, forKey: UserDefaultsKey.notifyOnNewRegion.rawValue)
        ubiquitousStore.set(summaryNotificationsEnabled, forKey: UserDefaultsKey.summaryNotificationsEnabled.rawValue)
        ubiquitousStore.set(photoPromptsEnabled, forKey: UserDefaultsKey.photoPromptsEnabled.rawValue)
        ubiquitousStore.set(inactivityReminderEnabled, forKey: UserDefaultsKey.inactivityReminderEnabled.rawValue)
        ubiquitousStore.set(inactivityReminderDays, forKey: UserDefaultsKey.inactivityReminderDays.rawValue)
        ubiquitousStore.set(minLatitudeDelta, forKey: UserDefaultsKey.minLatitudeDelta.rawValue)
        ubiquitousStore.set(minLongitudeDelta, forKey: UserDefaultsKey.minLongitudeDelta.rawValue)
        ubiquitousStore.set(minAltitudeDeltaMetersImperial, forKey: UserDefaultsKey.minAltitudeDeltaMetersImperial.rawValue)
        ubiquitousStore.set(minDistanceDeltaMetersImperial, forKey: UserDefaultsKey.minDistanceDeltaMetersImperial.rawValue)
        ubiquitousStore.set(minAltitudeDeltaMetersMetric, forKey: UserDefaultsKey.minAltitudeDeltaMetersMetric.rawValue)
        ubiquitousStore.set(minDistanceDeltaMetersMetric, forKey: UserDefaultsKey.minDistanceDeltaMetersMetric.rawValue)
        ubiquitousStore.set(homeAddress, forKey: UserDefaultsKey.homeAddress.rawValue)
        ubiquitousStore.set(unitSystem.rawValue, forKey: UserDefaultsKey.unitSystem.rawValue)

        if let homeLocationName = homeLocationName {
            ubiquitousStore.set(homeLocationName, forKey: UserDefaultsKey.homeLocationName.rawValue)
        }
        if let homeCoord = homeCoordinate {
            ubiquitousStore.set(homeCoord.latitude, forKey: UserDefaultsKey.homeLatitude.rawValue)
            ubiquitousStore.set(homeCoord.longitude, forKey: UserDefaultsKey.homeLongitude.rawValue)
        }

        // Sync iCloud Key-Value Store
        ubiquitousStore.synchronize()
        debugLog("☁️ Settings saved to iCloud - alerts: monthly=\(notifyOnMonthlyRecords), yearly=\(notifyOnYearlyRecords), allTime=\(notifyOnAllTimeRecords) | reminders: summary=\(summaryNotificationsEnabled), photo=\(photoPromptsEnabled), inactivity=\(inactivityReminderEnabled)")
    }
    
    func resetToDefaults() {
        // Reset setup state so wizard shows again
        hasCompletedSetup = false

        // Reset notification settings
        notifyOnMonthlyRecords = Self.defaultNotifyOnMonthlyRecords
        notifyOnYearlyRecords = Self.defaultNotifyOnYearlyRecords
        notifyOnAllTimeRecords = Self.defaultNotifyOnAllTimeRecords
        notifyOnNewRegion = Self.defaultNotifyOnNewRegion
        summaryNotificationsEnabled = Self.defaultSummaryNotificationsEnabled
        photoPromptsEnabled = Self.defaultPhotoPromptsEnabled
        inactivityReminderEnabled = Self.defaultInactivityReminderEnabled
        inactivityReminderDays = Self.defaultInactivityReminderDays

        // Reset delta settings
        minLatitudeDelta = Self.defaultMinLatitudeDelta
        minLongitudeDelta = Self.defaultMinLongitudeDelta
        minAltitudeDeltaMetersImperial = Self.defaultMinAltitudeDeltaMetersImperial
        minDistanceDeltaMetersImperial = Self.defaultMinDistanceDeltaMetersImperial
        minAltitudeDeltaMetersMetric = Self.defaultMinAltitudeDeltaMetersMetric
        minDistanceDeltaMetersMetric = Self.defaultMinDistanceDeltaMetersMetric

        // Reset home location
        homeAddress = Self.defaultHomeAddress
        homeCoordinate = Self.defaultHomeCoordinate
        homeLocationName = nil

        // Don't reset unitSystem - keep the current selection

        saveSettings()
        debugLog("⚙️ Settings reset to defaults")
    }

    /// Reset only delta values to defaults (used from Settings > Minimum Deltas)
    func resetDeltasToDefaults() {
        minLatitudeDelta = Self.defaultMinLatitudeDelta
        minLongitudeDelta = Self.defaultMinLongitudeDelta

        // Reset both Imperial and Metric to their respective defaults
        minAltitudeDeltaMetersImperial = Self.defaultMinAltitudeDeltaMetersImperial
        minDistanceDeltaMetersImperial = Self.defaultMinDistanceDeltaMetersImperial
        minAltitudeDeltaMetersMetric = Self.defaultMinAltitudeDeltaMetersMetric
        minDistanceDeltaMetersMetric = Self.defaultMinDistanceDeltaMetersMetric

        saveSettings()
    }

    /// Request notification permissions if any notification settings are enabled but permissions haven't been determined
    private func requestNotificationPermissionsIfNeeded() {
        // Check if any notification settings are enabled
        let hasNotificationsEnabled = notifyOnMonthlyRecords ||
                                     notifyOnYearlyRecords ||
                                     notifyOnAllTimeRecords ||
                                     notifyOnNewRegion ||
                                     summaryNotificationsEnabled ||
                                     inactivityReminderEnabled

        guard hasNotificationsEnabled else {
            return // No notifications enabled, nothing to do
        }

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            // Only request if permissions haven't been determined yet
            if settings.authorizationStatus == .notDetermined {
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                    debugLog("📱 Notification permissions requested (from iCloud sync) - granted: \(granted)")
                } catch {
                    debugLog("❌ Failed to request notification permissions: \(error.localizedDescription)")
                }
            }
        }
    }
}
