import SwiftUI
import CoreLocation
import UserNotifications

// MARK: - Location Health Status

/// Represents the overall health of location services for the app
enum LocationHealthStatus: Equatable {
    case healthy
    case degraded(reason: String, isSystemLevel: Bool = false)
    case disabled(reason: String, isSystemLevel: Bool = false)

    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    var isDisabled: Bool {
        if case .disabled = self { return true }
        return false
    }

    /// Whether this issue requires system-level settings (not app settings)
    var isSystemLevel: Bool {
        switch self {
        case .healthy:
            return false
        case .degraded(_, let isSystem), .disabled(_, let isSystem):
            return isSystem
        }
    }

    var message: String {
        switch self {
        case .healthy:
            return "Location services are working correctly"
        case .degraded(let reason, _), .disabled(let reason, _):
            return reason
        }
    }

    var icon: String {
        switch self {
        case .healthy:
            return "checkmark.circle.fill"
        case .degraded:
            return "exclamationmark.triangle.fill"
        case .disabled:
            return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            return .green
        case .degraded:
            return .orange
        case .disabled:
            return .red
        }
    }
}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private var locationManager = CLLocationManager()

    /// Publishes the user's current location so HomePickerView can use it.
    @Published var currentLocation: CLLocation?

    /// Current health status of location services
    @Published var healthStatus: LocationHealthStatus = .healthy

    /// Whether the user has dismissed the health banner
    @Published var healthBannerDismissed: Bool = false

    /// Cached authorization status to avoid blocking main thread
    private var cachedAuthorizationStatus: CLAuthorizationStatus?

    override init() {
        super.init()
        debugLog("LocationManager initialized")

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation

        // Only enable background updates if supported
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.allowsBackgroundLocationUpdates = true
            debugLog("Background location updates enabled")
        } else {
            debugLog("⚠️ Significant location change monitoring not available")
        }

        // Don't request authorization automatically - wait for user to start wizard
        // Start monitoring will begin after authorization is granted

        // Check health status asynchronously to avoid blocking main thread
        Task {
            await updateHealthStatusAsync()
        }
    }

    // MARK: - Health Check

    /// Check and update the overall health status of location services
    /// This synchronous version uses cached values when possible
    func updateHealthStatus() {
        // Use cached auth status if available, otherwise get current
        let authStatus = cachedAuthorizationStatus ?? locationManager.authorizationStatus
        cachedAuthorizationStatus = authStatus

        // Check authorization status first (doesn't block)
        switch authStatus {
        case .notDetermined:
            healthStatus = .disabled(reason: "Location permission not yet requested. Complete the setup wizard to enable tracking.")
            return
        case .restricted:
            healthStatus = .disabled(reason: "Location access is restricted. This may be due to parental controls or device management.")
            return
        case .denied:
            healthStatus = .disabled(reason: "Location permission denied. Enable it in Settings → GeoRecords → Location → Always.")
            return
        case .authorizedWhenInUse:
            healthStatus = .degraded(reason: "Only 'While Using' permission granted. For background tracking, change to 'Always' in Settings → GeoRecords → Location.")
            return
        case .authorizedAlways:
            // Good, continue to check accuracy
            break
        @unknown default:
            healthStatus = .degraded(reason: "Unknown location authorization status.")
            return
        }

        // Check accuracy authorization (iOS 14+)
        let accuracyAuth = locationManager.accuracyAuthorization
        if accuracyAuth == .reducedAccuracy {
            healthStatus = .degraded(reason: "Precise Location is off. Records may be inaccurate. Enable Precise Location in Settings → GeoRecords → Location.")
            return
        }

        // All checks passed
        healthStatus = .healthy
        healthBannerDismissed = false  // Reset dismissal when healthy
    }

    /// Async version that checks locationServicesEnabled on background thread
    @MainActor
    func updateHealthStatusAsync() async {
        // Check if location services are enabled globally (can block, so run on background)
        let servicesEnabled = await Task.detached {
            CLLocationManager.locationServicesEnabled()
        }.value

        guard servicesEnabled else {
            healthStatus = .disabled(reason: "Location Services are turned off. Enable them in Settings → Privacy & Security → Location Services.", isSystemLevel: true)
            return
        }

        // Now check the rest synchronously (these don't block)
        updateHealthStatus()
    }

    /// Open the app's settings page
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Inactivity Reminder

    private let inactivityReminderIdentifier = "georecords-inactivity-reminder"

    /// Schedule or reschedule the inactivity reminder notification
    /// Called each time the app becomes active
    @MainActor
    func scheduleInactivityReminder() {
        let settings = SettingsManager.shared

        // Cancel any existing reminder first
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [inactivityReminderIdentifier]
        )

        // Only schedule if enabled and we have notification permission
        guard settings.inactivityReminderEnabled else {
            debugLog("📅 Inactivity reminder disabled, not scheduling")
            return
        }

        // Capture values before async work to avoid Sendable issues
        let days = settings.inactivityReminderDays
        let identifier = inactivityReminderIdentifier

        guard days > 0 else { return }

        // Check notification permission and schedule
        Task {
            let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()

            guard notificationSettings.authorizationStatus == .authorized else {
                debugLog("📅 Notifications not authorized, not scheduling inactivity reminder")
                return
            }

            // Schedule notification for X days from now
            let content = UNMutableNotificationContent()
            content.title = "Missing Your Adventures!"
            content.body = "GeoRecords hasn't tracked any locations in \(days) days. Open the app to make sure location tracking is still working."
            content.sound = .default

            // Trigger after X days
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(days * 24 * 60 * 60),
                repeats: false
            )

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
                debugLog("📅 Scheduled inactivity reminder for \(days) days from now")
            } catch {
                debugLog("📅 Failed to schedule inactivity reminder: \(error)")
            }
        }
    }

    /// Cancel any pending inactivity reminder
    func cancelInactivityReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [inactivityReminderIdentifier]
        )
        debugLog("📅 Cancelled inactivity reminder")
    }

    /// Request location authorization - should be called from setup wizard
    func requestLocationAuthorization() {
        debugLog("Requesting location authorization")
        locationManager.requestAlwaysAuthorization()
        startLocationMonitoring()
    }

    func startLocationMonitoring() {
        debugLog("Starting significant location change monitoring (background-compatible)")
        locationManager.startMonitoringSignificantLocationChanges()
    }

    func stopLocationMonitoring() {
        debugLog("Stopping significant location change monitoring")
        locationManager.stopMonitoringSignificantLocationChanges()
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let currentLocation = locations.last else {
            debugLog("No location returned")
            return
        }
        debugLog("Received location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude), altitude: \(currentLocation.altitude)")

        // Ensure all @Published property updates and MainActor calls happen on main thread
        Task { @MainActor in
            self.currentLocation = currentLocation
            RecordManager.shared.updateRecords(with: currentLocation)
            // Smart Notifications retired - removed call to SmartNotificationManager

            // Track visited region (background location update - auto-confirmed, no user intervention)
            RegionTrackingManager.shared.recordVisit(
                coordinate: currentLocation.coordinate,
                date: Date(),
                source: .backgroundLocation,
                altitude: currentLocation.altitude
            )
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        debugLog("Location update failed: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Update cached status
        cachedAuthorizationStatus = manager.authorizationStatus

        switch manager.authorizationStatus {
        case .authorizedAlways:
            debugLog("✅ Always authorization granted - background tracking enabled")
            startLocationMonitoring()
        case .authorizedWhenInUse:
            debugLog("⚠️ Only 'When In Use' authorization - background tracking will be limited")
            startLocationMonitoring()
        case .denied:
            debugLog("❌ Location authorization denied - app cannot track records")
        case .restricted:
            debugLog("❌ Location authorization restricted - app cannot track records")
        case .notDetermined:
            debugLog("📍 Location authorization not yet determined")
            // Will be called again after user responds to permission request
        @unknown default:
            debugLog("⚠️ Unknown authorization status")
        }

        // Update health status whenever authorization changes
        updateHealthStatus()
    }
}
