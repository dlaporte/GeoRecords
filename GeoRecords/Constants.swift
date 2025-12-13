import Foundation
import SwiftUI
import MapKit
import CoreLocation

// MARK: - Shared Models

/// Unit system for displaying values
enum UnitSystem: String, Codable {
    case metric
    case imperial
}

/// Time frame for records
enum TimeFrame: String, CaseIterable {
    case month = "Monthly"
    case year = "Yearly"
    case allTime = "All Time"
}

/// Record type enum for type safety and comparison logic
enum RecordType: String, CaseIterable {
    case north = "Furthest North"
    case south = "Furthest South"
    case east = "Furthest East"
    case west = "Furthest West"
    case up = "Furthest Up"
    case down = "Furthest Down"
    case fromHome = "Furthest from Home"

    /// Whether this record type uses ascending comparison (higher is better)
    var isAscending: Bool {
        switch self {
        case .north, .east, .up, .fromHome:
            return true  // Higher values are better
        case .south, .west, .down:
            return false  // Lower values are better
        }
    }

    /// Determine if a new value should replace an existing record
    func shouldReplace(newValue: Double, oldValue: Double) -> Bool {
        return isAscending ? newValue > oldValue : newValue < oldValue
    }

    /// All record type strings for compatibility
    static var allTypeStrings: [String] {
        return RecordType.allCases.map { $0.rawValue }
    }

    /// Get record type from string (for backward compatibility)
    static func from(string: String) -> RecordType? {
        return RecordType.allCases.first { $0.rawValue == string }
    }
}

// MARK: - UserDefaults Keys

/// Type-safe keys for UserDefaults storage
enum UserDefaultsKey: String {
    // Setup
    case hasCompletedSetup

    // Notification settings
    case notifyOnMonthlyRecords
    case notifyOnYearlyRecords
    case notifyOnAllTimeRecords
    case summaryNotificationsEnabled
    case photoPromptsEnabled

    // Smart notifications
    case smartNotificationsEnabled
    case lastInactivityNotification
    case lastFunFactNotification

    // Inactivity reminder
    case inactivityReminderEnabled
    case inactivityReminderDays

    // Record thresholds
    case minLatitudeDelta
    case minLongitudeDelta
    case minAltitudeDeltaMetersImperial
    case minDistanceDeltaMetersImperial
    case minAltitudeDeltaMetersMetric
    case minDistanceDeltaMetersMetric

    // Home location
    case homeAddress
    case homeLocationName
    case homeLatitude
    case homeLongitude

    // Units
    case unitSystem

    // Legacy keys (for migration)
    case notifyOnNewRecord  // Migrated to timeframe-specific settings
    case minAltitudeDeltaFeet  // Migrated to meters
    case minAltitudeDeltaMeters  // Migrated to unit-specific
    case minDistanceDeltaMeters  // Migrated to unit-specific
    case monthlySummaryEnabled  // Migrated to summaryNotificationsEnabled
    case yearlySummaryEnabled  // Migrated to summaryNotificationsEnabled
}

// MARK: - Debug Logging

/// Debug print that only outputs in DEBUG builds
func debugLog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    print(items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
    #endif
}

// MARK: - Unit Conversion Constants

/// Meters to feet conversion factor
let metersToFeet = 3.28084

/// Feet to meters conversion factor
let feetToMeters = 0.3048

/// Feet per mile
let feetPerMile = 5280.0

/// Meters per mile
let metersPerMile = 1609.344

/// Meters per kilometer
let metersPerKm = 1000.0

// MARK: - Distance Utilities

/// Calculates distance between two coordinates in meters
/// - Parameters:
///   - from: Starting coordinate
///   - to: Destination coordinate
/// - Returns: Distance in meters
func distanceBetween(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    let fromLocation = CLLocation(latitude: from.latitude, longitude: from.longitude)
    let toLocation = CLLocation(latitude: to.latitude, longitude: to.longitude)
    return fromLocation.distance(from: toLocation)
}

// MARK: - Geocoding Utilities

/// Reverse geocodes a location to get a human-readable name
/// - Parameter location: The location to geocode
/// - Returns: Formatted location name or nil if geocoding fails
@available(iOS, deprecated: 26.0, message: "Use MapKit geocoding when API stabilizes")
func reverseGeocode(location: CLLocation) async -> String? {
    let geocoder = CLGeocoder()
    do {
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        if let placemark = placemarks.first {
            return FormatUtils.formatPlacemarkName(placemark)
        }
    } catch {
        debugLog("Geocoding error: \(error.localizedDescription)")
    }
    return nil
}

/// Reverse geocodes a coordinate to get a human-readable name
/// - Parameter coordinate: The coordinate to geocode
/// - Returns: Formatted location name or nil if geocoding fails
@available(iOS, deprecated: 26.0, message: "Use MapKit geocoding when API stabilizes")
func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> String? {
    let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    return await reverseGeocode(location: location)
}

// MARK: - MapKit Constants

/// Default map zoom level for record details (~5km at equator)
let defaultMapLatDelta = 0.05
let defaultMapLonDelta = 0.05

/// Wide map zoom level for overview
let wideMapLatDelta = 2.0
let wideMapLonDelta = 2.0

// MARK: - UI Constants

/// Screen height threshold for compact layout (iPhone 14/15 and smaller)
let compactScreenHeightThreshold: CGFloat = 850

// MARK: - Location Validation Constants

/// Threshold for detecting "Null Island" (0,0) coordinates - approximately 1km
let nullIslandCoordinateThreshold = 0.01

/// Threshold for detecting zero altitude at Null Island
let nullIslandAltitudeThreshold = 1.0

/// Maximum realistic altitude on Earth (meters) - Mount Everest is 8,849m
let maxRealisticAltitudeMeters = 9000.0

/// Minimum altitude to trigger terrain validation during photo import (3000ft in meters)
let terrainValidationAltitudeThreshold = 914.4

/// Maximum allowed altitude above terrain before rejecting (1500ft in meters)
let maxAltitudeAboveTerrainMeters = 457.2

/// Coordinate tolerance for duplicate detection (approximately 1 meter)
let duplicateCoordinateTolerance = 0.00001

/// Value tolerance for duplicate detection
let duplicateValueTolerance = 0.0001

/// Time tolerance for duplicate detection (in seconds)
let duplicateTimeTolerance: TimeInterval = 1.0

// MARK: - Location Validation Utilities

/// Result of location validation
enum LocationValidationResult {
    case valid
    case nullIsland
    case unrealisticAltitude(meters: Double)
}

/// Validates a location for recording
/// - Parameters:
///   - latitude: The latitude coordinate
///   - longitude: The longitude coordinate
///   - altitude: The altitude in meters
/// - Returns: Validation result indicating if location is valid or why it's invalid
func validateLocation(latitude: Double, longitude: Double, altitude: Double) -> LocationValidationResult {
    // Check for "Null Island" (0,0 with ~0 altitude) - placeholder values for missing GPS
    let isNullIsland = abs(latitude) < nullIslandCoordinateThreshold &&
                       abs(longitude) < nullIslandCoordinateThreshold &&
                       abs(altitude) < nullIslandAltitudeThreshold
    if isNullIsland {
        return .nullIsland
    }

    // Check for unrealistic altitudes (above Mount Everest)
    if altitude > maxRealisticAltitudeMeters {
        return .unrealisticAltitude(meters: altitude)
    }

    return .valid
}

/// Validates a CLLocation for recording
/// - Parameter location: The location to validate
/// - Returns: Validation result indicating if location is valid or why it's invalid
func validateLocation(_ location: CLLocation) -> LocationValidationResult {
    return validateLocation(
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude,
        altitude: location.altitude
    )
}

// MARK: - Photo Import Constants

/// Batch size for processing photos during library scan
let photoScanBatchSize = 100

/// Duration to suppress notifications after photo import (in seconds)
let postImportNotificationSuppressionSeconds: TimeInterval = 180

/// Same value in nanoseconds for Task.sleep
let postImportNotificationSuppressionNanoseconds: UInt64 = 180_000_000_000

// MARK: - Notification Identifiers

/// Notification identifier constants for consistent deduplication
enum NotificationIdentifier {
    static let monthlySummary = "monthly-summary"
    static let yearlySummary = "yearly-summary"
    static let inactivity = "inactivity"
    static let funFact = "fun-fact"

    /// Creates a notification identifier for a new record notification
    /// Using a consistent ID per record type allows deduplication
    static func newRecord(type: String) -> String {
        return "new-record-\(type.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }
}

// MARK: - Date Formatters

/// Shared date formatter for detailed date display
let detailDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
}()

/// Shared compact date formatter for history list
let compactDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM/dd/yy HH:mm"
    return formatter
}()

/// Shared medium date formatter (date only, no time)
let mediumDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter
}()

// MARK: - Date Extensions

extension Date {
    /// Returns the start of the current month and year for timeframe calculations
    static func timeFrameBoundaries() -> (month: Date, year: Date) {
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let startOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now
        return (startOfMonth, startOfYear)
    }

    /// Returns the start date of the previous month or year (for summary calculations)
    /// - Parameter timeFrame: The time frame to get the previous period for
    /// - Returns: The start date of the previous period
    static func startOfPreviousPeriod(for timeFrame: TimeFrame) -> Date {
        let calendar = Calendar.current
        let now = Date()

        switch timeFrame {
        case .month:
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .month, for: lastMonth)?.start ?? now
        case .year:
            let lastYear = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .year, for: lastYear)?.start ?? now
        case .allTime:
            return Date.distantPast
        }
    }
}

// MARK: - Array Extensions

/// Safe array subscript that returns nil instead of crashing on out-of-bounds access
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - MapKit Extensions

extension MapCameraPosition {
    /// Creates a map camera position centered on a coordinate with standard zoom level
    /// - Parameters:
    ///   - coordinate: The coordinate to center on
    ///   - latitudeDelta: The latitude span (defaults to 0.05, about 5km)
    ///   - longitudeDelta: The longitude span (defaults to 0.05)
    /// - Returns: A MapCameraPosition centered on the coordinate
    static func centered(
        on coordinate: CLLocationCoordinate2D,
        latitudeDelta: Double = 0.05,
        longitudeDelta: Double = 0.05
    ) -> MapCameraPosition {
        return .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        ))
    }
}
