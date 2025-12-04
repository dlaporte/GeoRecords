import Foundation

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

// MARK: - Date Formatters

/// Shared date formatter for displaying record timestamps
let recordDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

/// Shared date formatter for detailed date display
let detailDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
}()
