import Foundation
import SwiftUI
import MapKit

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

// MARK: - MapKit Constants

/// Default map zoom level for record details (~5km at equator)
let defaultMapLatDelta = 0.05
let defaultMapLonDelta = 0.05

/// Wide map zoom level for overview
let wideMapLatDelta = 2.0
let wideMapLonDelta = 2.0

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
