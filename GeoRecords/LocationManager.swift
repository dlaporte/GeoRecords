import SwiftUI
import CoreLocation
import Combine

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()
    
    private var locationManager = CLLocationManager()
    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    
    /// NEW: Publishes the user’s current location so HomePickerView can use it.
    @Published var currentLocation: CLLocation?
    
    override init() {
        super.init()
        print("LocationManager initialized")
        
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.requestAlwaysAuthorization()
        
        startTimer()
        
        // Observe changes to timer interval.
        SettingsManager.shared.$timerInterval
            .sink { [weak self] newInterval in
                print("Timer interval changed to \(newInterval) seconds")
                self?.startTimer()
            }
            .store(in: &cancellables)
    }
    
    func startTimer() {
        // Cancel existing timer if any.
        timer?.cancel()
        timer = nil
        
        let interval = SettingsManager.shared.timerInterval
        print("Starting DispatchSourceTimer with interval: \(interval) seconds")
        
        // Create a DispatchSourceTimer on the main queue.
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer?.schedule(deadline: .now() + interval, repeating: interval)
        timer?.setEventHandler { [weak self] in
            print("DispatchSourceTimer fired, requesting location...")
            self?.locationManager.requestLocation()
        }
        timer?.resume()
        
        // Uncomment this block to test with a simple Timer instead.
        /*
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            print("Simple Timer fired, requesting location...")
            self.locationManager.requestLocation()
        }
        */
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let currentLocation = locations.last else {
            print("No location returned")
            return
        }
        print("Received location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude), altitude: \(currentLocation.altitude)")
        
        // NEW: Publish this location so HomePickerView can read it.
        self.currentLocation = currentLocation
        
        // Forward location to RecordManager (if needed)
        RecordManager.shared.updateRecords(with: currentLocation)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location update failed: \(error.localizedDescription)")
    }
}
