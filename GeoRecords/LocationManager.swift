import SwiftUI
import CoreLocation

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private var locationManager = CLLocationManager()

    /// Publishes the user's current location so HomePickerView can use it.
    @Published var currentLocation: CLLocation?

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
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        debugLog("Location update failed: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
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
    }
}
