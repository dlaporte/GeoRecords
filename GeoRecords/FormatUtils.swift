import SwiftUI
import CoreLocation

/// Shared formatting utilities for GeoRecords app
enum FormatUtils {

    // MARK: - Record Type Display Names

    static func shortName(for recordType: String) -> String {
        switch recordType {
        case "Furthest North": return "North"
        case "Furthest South": return "South"
        case "Furthest East": return "East"
        case "Furthest West": return "West"
        case "Furthest Up": return "Up"
        case "Furthest Down": return "Down"
        case "Furthest from Home": return "From Home"
        default: return recordType
        }
    }

    // MARK: - Icons

    static func iconForRecordType(_ type: String) -> String {
        switch type {
        case "Furthest North": return "arrow.up.circle.fill"
        case "Furthest South": return "arrow.down.circle.fill"
        case "Furthest East": return "arrow.right.circle.fill"
        case "Furthest West": return "arrow.left.circle.fill"
        case "Furthest Up": return "mountain.2.fill"
        case "Furthest Down": return "water.waves"
        case "Furthest from Home": return "house.circle.fill"
        default: return "location.circle.fill"
        }
    }

    // MARK: - Colors

    static func colorForRecordType(_ type: String) -> Color {
        switch type {
        case "Furthest North": return .blue
        case "Furthest South": return .cyan
        case "Furthest East": return .orange
        case "Furthest West": return .purple
        case "Furthest Up": return .green
        case "Furthest Down": return .brown
        case "Furthest from Home": return .red
        default: return .gray
        }
    }

    // MARK: - Value Formatting

    static func formatValue(value: Double, recordType: String, unitSystem: UnitSystem) -> String {
        switch recordType {
        case "Furthest North", "Furthest South":
            return String(format: "%.4f°", value)

        case "Furthest East", "Furthest West":
            return String(format: "%.4f°", value)

        case "Furthest Up", "Furthest Down":
            // Value is stored in meters
            if unitSystem == .imperial {
                let feet = value * metersToFeet
                return String(format: "%.0f ft", feet)
            } else {
                return String(format: "%.0f m", value)
            }

        case "Furthest from Home":
            // Value is stored in feet
            if unitSystem == .imperial {
                let miles = value / feetPerMile
                return String(format: "%.2f mi", miles)
            } else {
                let meters = value * feetToMeters
                let km = meters / metersPerKm
                return String(format: "%.2f km", km)
            }

        default:
            return "\(value)"
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

        let recordLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
        let distanceMeters = recordLocation.distance(from: homeLocation)

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
        switch recordType {
        case "Furthest North", "Furthest South":
            return String(format: "%.4f°", coordinate.latitude)

        case "Furthest East", "Furthest West":
            return String(format: "%.4f°", coordinate.longitude)

        case "Furthest Up", "Furthest Down":
            return "Altitude not available"

        case "Furthest from Home":
            guard let homeCoord = homeCoordinate else {
                return "Set home location first"
            }
            let recordLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let distance = recordLocation.distance(from: homeLocation)

            if unitSystem == .imperial {
                let miles = distance / metersPerMile
                return String(format: "%.2f mi", miles)
            } else {
                let km = distance / metersPerKm
                return String(format: "%.2f km", km)
            }

        default:
            return ""
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
        if recordType.contains("North") || recordType.contains("South") ||
           recordType.contains("East") || recordType.contains("West") {
            return String(format: "%.\(coordinatePrecision)f°", value)
        } else if recordType.contains("Up") || recordType.contains("Down") {
            if unitSystem == .imperial {
                let feet = altitude * metersToFeet
                return String(format: "%.0f ft", feet)
            } else {
                return String(format: "%.0f m", altitude)
            }
        } else if recordType == "Furthest from Home" {
            if unitSystem == .imperial {
                let miles = value / feetPerMile
                return String(format: "%.2f mi", miles)
            } else {
                let meters = value * feetToMeters
                let km = meters / metersPerKm
                return String(format: "%.2f km", km)
            }
        }
        return String(format: "%.2f", value)
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
