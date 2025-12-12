import SwiftUI
import CoreLocation

/// Shared formatting utilities for GeoRecords app
enum FormatUtils {

    // MARK: - Record Type Display Names

    static func shortName(for recordType: String) -> String {
        guard let type = RecordType.from(string: recordType) else { return recordType }
        switch type {
        case .north: return "North"
        case .south: return "South"
        case .east: return "East"
        case .west: return "West"
        case .up: return "Up"
        case .down: return "Down"
        case .fromHome: return "From Home"
        }
    }

    // MARK: - Icons

    static func iconForRecordType(_ type: String) -> String {
        guard let recordType = RecordType.from(string: type) else { return "location.circle.fill" }
        switch recordType {
        case .north: return "arrow.up.circle.fill"
        case .south: return "arrow.down.circle.fill"
        case .east: return "arrow.right.circle.fill"
        case .west: return "arrow.left.circle.fill"
        case .up: return "mountain.2.fill"
        case .down: return "water.waves"
        case .fromHome: return "house.circle.fill"
        }
    }

    /// Returns an emoji prefix for a record type
    static func emojiForRecordType(_ type: String) -> String {
        guard let recordType = RecordType.from(string: type) else { return "" }
        switch recordType {
        case .north: return "⬆️"
        case .south: return "⬇️"
        case .east: return "➡️"
        case .west: return "⬅️"
        case .up: return "🏔"
        case .down: return "🏖"
        case .fromHome: return "🏠"
        }
    }

    /// Returns a formatted label with emoji and short name for a record type
    static func emojiLabel(for recordType: String) -> String {
        let emoji = emojiForRecordType(recordType)
        let short = shortName(for: recordType)
        return "\(emoji) \(short)"
    }

    // MARK: - Colors

    static func colorForRecordType(_ type: String) -> Color {
        guard let recordType = RecordType.from(string: type) else { return .gray }
        switch recordType {
        case .north: return .blue
        case .south: return .cyan
        case .east: return .orange
        case .west: return .purple
        case .up: return .green
        case .down: return .brown
        case .fromHome: return .red
        }
    }

    // MARK: - Value Formatting

    static func formatValue(value: Double, recordType: String, unitSystem: UnitSystem) -> String {
        guard let type = RecordType.from(string: recordType) else { return "\(value)" }

        switch type {
        case .north, .south, .east, .west:
            return String(format: "%.4f°", value)

        case .up, .down:
            // Value is stored in meters
            if unitSystem == .imperial {
                let feet = value * metersToFeet
                return String(format: "%.0f ft", feet)
            } else {
                return String(format: "%.0f m", value)
            }

        case .fromHome:
            // Value is stored in meters (consistent with altitude)
            if unitSystem == .imperial {
                let miles = value / metersPerMile
                return String(format: "%.2f mi", miles)
            } else {
                let km = value / metersPerKm
                return String(format: "%.2f km", km)
            }
        }
    }

    // MARK: - Distance Formatting

    /// Formats distance from home for display
    /// - Parameters:
    ///   - coordinate: The record's coordinate
    ///   - homeCoordinate: The home location coordinate
    ///   - unitSystem: The unit system to use for formatting
    /// - Returns: Formatted distance string, or nil if home not set
    static func formatDistanceFromHome(
        from coordinate: CLLocationCoordinate2D,
        to homeCoordinate: CLLocationCoordinate2D?,
        unitSystem: UnitSystem
    ) -> String? {
        guard let homeCoord = homeCoordinate else {
            return nil
        }

        let distanceMeters = distanceBetween(from: coordinate, to: homeCoord)

        if unitSystem == .imperial {
            let miles = distanceMeters / metersPerMile
            return String(format: "%.2f mi", miles)
        } else {
            if distanceMeters >= metersPerKm {
                let km = distanceMeters / metersPerKm
                return String(format: "%.2f km", km)
            } else {
                return String(format: "%.0f m", distanceMeters)
            }
        }
    }

    /// Formats a record value from a coordinate and record type
    /// Used for displaying potential record values before they're saved
    /// - Parameters:
    ///   - recordType: The type of record
    ///   - coordinate: The location coordinate
    ///   - homeCoordinate: Optional home coordinate (required for "Furthest from Home")
    ///   - unitSystem: The unit system to use for formatting
    /// - Returns: Formatted value string
    static func formatRecordValue(
        for recordType: String,
        at coordinate: CLLocationCoordinate2D,
        homeCoordinate: CLLocationCoordinate2D? = nil,
        unitSystem: UnitSystem
    ) -> String {
        guard let type = RecordType.from(string: recordType) else { return "" }

        switch type {
        case .north, .south:
            return String(format: "%.4f°", coordinate.latitude)

        case .east, .west:
            return String(format: "%.4f°", coordinate.longitude)

        case .up, .down:
            return "Altitude not available"

        case .fromHome:
            guard let homeCoord = homeCoordinate else {
                return "Set home location first"
            }
            let distance = distanceBetween(from: coordinate, to: homeCoord)

            if unitSystem == .imperial {
                let miles = distance / metersPerMile
                return String(format: "%.2f mi", miles)
            } else {
                let km = distance / metersPerKm
                return String(format: "%.2f km", km)
            }
        }
    }

    /// Formats a discovered record value for display
    /// - Parameters:
    ///   - recordType: The type of record
    ///   - value: The record value (latitude, longitude, distance, etc.)
    ///   - altitude: The altitude value (for Up/Down records)
    ///   - unitSystem: The unit system to use
    ///   - precision: Coordinate precision (default: 4 for record confirmation, 2 for lists)
    /// - Returns: Formatted value string
    static func formatDiscoveredRecordValue(
        recordType: String,
        value: Double,
        altitude: Double,
        unitSystem: UnitSystem,
        coordinatePrecision: Int = 4
    ) -> String {
        guard let type = RecordType.from(string: recordType) else {
            return String(format: "%.2f", value)
        }

        switch type {
        case .north, .south, .east, .west:
            return String(format: "%.\(coordinatePrecision)f°", value)

        case .up, .down:
            if unitSystem == .imperial {
                let feet = altitude * metersToFeet
                return String(format: "%.0f ft", feet)
            } else {
                return String(format: "%.0f m", altitude)
            }

        case .fromHome:
            // Value is stored in meters
            if unitSystem == .imperial {
                let miles = value / metersPerMile
                return String(format: "%.2f mi", miles)
            } else {
                let km = value / metersPerKm
                return String(format: "%.2f km", km)
            }
        }
    }

    /// Formats a CLPlacemark into a human-readable location name
    /// - Parameter placemark: The placemark to format
    /// - Returns: Formatted location name (e.g., "San Francisco, CA, United States")
    static func formatPlacemarkName(_ placemark: CLPlacemark) -> String {
        var components: [String] = []

        if let locality = placemark.locality {
            components.append(locality)
        }
        if let adminArea = placemark.administrativeArea {
            components.append(adminArea)
        }
        if let country = placemark.country {
            components.append(country)
        }

        return components.isEmpty ? "Unknown Location" : components.joined(separator: ", ")
    }
}
