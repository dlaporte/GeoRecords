import SwiftUI
import CoreLocation
import MapKit

/// Shared formatting utilities for GeoRecords app
enum FormatUtils {

    // MARK: - Locale-Aware Number Formatting

    /// Shared number formatter for distances (no decimal places)
    private static let wholeNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    /// Shared number formatter for distances (1 decimal place)
    private static let oneDecimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 1
        return formatter
    }()

    /// Shared number formatter for distances (2 decimal places)
    private static let twoDecimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    /// Format a number with locale-appropriate separators (no decimals)
    /// Example: 2000 -> "2,000" (US) or "2.000" (DE)
    static func formatWholeNumber(_ value: Double) -> String {
        wholeNumberFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    /// Format a number with locale-appropriate separators (1 decimal)
    /// Example: 2000.5 -> "2,000.5" (US) or "2.000,5" (DE)
    static func formatOneDecimal(_ value: Double) -> String {
        oneDecimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// Format a number with locale-appropriate separators (2 decimals)
    /// Example: 2000.55 -> "2,000.55" (US) or "2.000,55" (DE)
    static func formatTwoDecimal(_ value: Double) -> String {
        twoDecimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// Format distance in miles with locale-appropriate separators
    static func formatMiles(_ miles: Double, decimals: Int = 1) -> String {
        switch decimals {
        case 0: return "\(formatWholeNumber(miles)) mi"
        case 1: return "\(formatOneDecimal(miles)) mi"
        default: return "\(formatTwoDecimal(miles)) mi"
        }
    }

    /// Format distance in kilometers with locale-appropriate separators
    static func formatKilometers(_ km: Double, decimals: Int = 1) -> String {
        switch decimals {
        case 0: return "\(formatWholeNumber(km)) km"
        case 1: return "\(formatOneDecimal(km)) km"
        default: return "\(formatTwoDecimal(km)) km"
        }
    }

    /// Format elevation in feet with locale-appropriate separators
    static func formatFeet(_ feet: Double) -> String {
        "\(formatWholeNumber(feet)) ft"
    }

    /// Format elevation in meters with locale-appropriate separators
    static func formatMeters(_ meters: Double) -> String {
        "\(formatWholeNumber(meters)) m"
    }

    /// Format distance using the appropriate unit system
    /// - Parameters:
    ///   - value: Distance value (already in miles or km based on unit system)
    ///   - unitSystem: The unit system to use for formatting
    ///   - decimals: Number of decimal places (default: 0)
    /// - Returns: Formatted distance string with unit suffix
    static func formatDistance(_ value: Double, unitSystem: UnitSystem, decimals: Int = 0) -> String {
        unitSystem == .imperial
            ? formatMiles(value, decimals: decimals)
            : formatKilometers(value, decimals: decimals)
    }

    // MARK: - Record Type Display Names

    static func shortName(for recordType: String) -> String {
        guard let type = RecordType.from(string: recordType) else { return recordType }
        switch type {
        case .north: return "North"
        case .south: return "South"
        case .east: return "East"
        case .west: return "West"
        case .up: return "Up"
        case .fromHome: return "From Home"
        case .state: return "State"
        case .country: return "Country"
        case .continent: return "Continent"
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
        case .fromHome: return "house.circle.fill"
        case .state: return "flag.fill"
        case .country: return "globe.americas.fill"
        case .continent: return "globe"
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
        case .fromHome: return "🏠"
        case .state: return "🏴"
        case .country: return "🌍"
        case .continent: return "🌎"
        }
    }

    /// Returns a formatted label with emoji and short name for a record type
    static func emojiLabel(for recordType: String) -> String {
        let emoji = emojiForRecordType(recordType)
        let short = shortName(for: recordType)
        return "\(emoji) \(short)"
    }

    // MARK: - Flag Emoji

    /// Convert a country/territory region code to a flag emoji
    /// For territories, uses the parent country's flag via RegionLookupService
    /// - Parameters:
    ///   - regionCode: The ISO 2-letter country code or territory code (e.g., "US", "FR", "PT-20")
    ///   - recordType: The record type string (only returns flags for country records)
    /// - Returns: Flag emoji string, or nil if not a country or invalid code
    static func flagEmoji(for regionCode: String?, recordType: String) -> String? {
        guard let code = regionCode else { return nil }

        // Only show flags for countries, not states or continents
        guard recordType == RecordType.country.rawValue else { return nil }

        // Get the flag code - for territories, this returns parent country code
        guard let flagCode = flagCodeForRegion(code) else { return nil }

        // Convert ISO 2-letter code to flag emoji
        // Flag emojis are created by combining regional indicator symbols
        let uppercaseCode = flagCode.uppercased()
        guard uppercaseCode.count == 2 else { return nil }

        var flagString = ""
        for scalar in uppercaseCode.unicodeScalars {
            // Regional indicator symbols start at U+1F1E6 (A) through U+1F1FF (Z)
            if let regionalIndicator = UnicodeScalar(127397 + scalar.value) {
                flagString.append(String(regionalIndicator))
            }
        }

        return flagString.isEmpty ? nil : flagString
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
        case .fromHome: return .red
        case .state: return .orange
        case .country: return .blue
        case .continent: return .purple
        }
    }

    // MARK: - Value Formatting

    static func formatValue(value: Double, recordType: String, unitSystem: UnitSystem) -> String {
        guard let type = RecordType.from(string: recordType) else { return "\(value)" }

        switch type {
        case .north, .south, .east, .west:
            return String(format: "%.4f°", value)

        case .up:
            // Value is stored in meters
            if unitSystem == .imperial {
                return formatFeet(value * metersToFeet)
            } else {
                return formatMeters(value)
            }

        case .fromHome:
            // Value is stored in meters (consistent with altitude)
            if unitSystem == .imperial {
                return formatMiles(value / metersPerMile, decimals: 0)
            } else {
                return formatKilometers(value / metersPerKm, decimals: 0)
            }

        case .state, .country, .continent:
            // Value is stored as Unix timestamp - format as date
            let date = Date(timeIntervalSince1970: value)
            return numericDateFormatter.string(from: date)
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
            return formatMiles(distanceMeters / metersPerMile, decimals: 0)
        } else {
            if distanceMeters >= metersPerKm {
                return formatKilometers(distanceMeters / metersPerKm, decimals: 0)
            } else {
                return formatMeters(distanceMeters)
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

        case .up:
            return "Altitude not available"

        case .fromHome:
            guard let homeCoord = homeCoordinate else {
                return "Set home location first"
            }
            let distance = distanceBetween(from: coordinate, to: homeCoord)

            if unitSystem == .imperial {
                return formatMiles(distance / metersPerMile, decimals: 0)
            } else {
                return formatKilometers(distance / metersPerKm, decimals: 0)
            }

        case .state, .country, .continent:
            // Region records are created from actual visits, not predicted
            return "Visit to create record"
        }
    }

    /// Formats a discovered record value for display
    /// - Parameters:
    ///   - recordType: The type of record
    ///   - value: The record value (latitude, longitude, distance, etc.)
    ///   - altitude: The altitude value (for Up records)
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
            return formatTwoDecimal(value)
        }

        switch type {
        case .north, .south, .east, .west:
            return String(format: "%.\(coordinatePrecision)f°", value)

        case .up:
            if unitSystem == .imperial {
                return formatFeet(altitude * metersToFeet)
            } else {
                return formatMeters(altitude)
            }

        case .fromHome:
            // Value is stored in meters
            if unitSystem == .imperial {
                return formatMiles(value / metersPerMile, decimals: 0)
            } else {
                return formatKilometers(value / metersPerKm, decimals: 0)
            }

        case .state, .country, .continent:
            // Value is stored as Unix timestamp - format as date
            let date = Date(timeIntervalSince1970: value)
            return numericDateFormatter.string(from: date)
        }
    }

    // MARK: - Coordinate Formatting

    /// Formats a coordinate pair as a string
    /// - Parameters:
    ///   - latitude: The latitude value
    ///   - longitude: The longitude value
    ///   - precision: Number of decimal places (default: 4, which gives ~11m accuracy)
    /// - Returns: Formatted coordinate string (e.g., "37.7749, -122.4194")
    static func formatCoordinates(_ latitude: Double, _ longitude: Double, precision: Int = 4) -> String {
        String(format: "%.\(precision)f, %.\(precision)f", latitude, longitude)
    }

    /// Formats a CLLocationCoordinate2D as a string
    /// - Parameters:
    ///   - coordinate: The coordinate to format
    ///   - precision: Number of decimal places (default: 4)
    /// - Returns: Formatted coordinate string
    static func formatCoordinates(_ coordinate: CLLocationCoordinate2D, precision: Int = 4) -> String {
        formatCoordinates(coordinate.latitude, coordinate.longitude, precision: precision)
    }

    /// Formats coordinates with cardinal directions (e.g., "37.7749° N, 122.4194° W")
    /// - Parameters:
    ///   - coordinate: The coordinate to format
    ///   - precision: Number of decimal places (default: 4)
    /// - Returns: Formatted coordinate string with cardinal directions
    static func formatCoordinatesWithCardinals(_ coordinate: CLLocationCoordinate2D, precision: Int = 4) -> String {
        let latDir = coordinate.latitude >= 0 ? "N" : "S"
        let lonDir = coordinate.longitude >= 0 ? "E" : "W"
        return String(format: "%.\(precision)f° %@, %.\(precision)f° %@",
                      abs(coordinate.latitude), latDir,
                      abs(coordinate.longitude), lonDir)
    }

    // MARK: - Placemark Formatting

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

// MARK: - Photo Library Utilities

import Photos

/// Shared utility for getting cloud identifiers from photo assets
/// Consolidates duplicate implementations from PhotoLibraryScanner, RegionTrackingManager, ManualRecordImportView
extension PHPhotoLibrary {
    /// Get the cloud identifier for a photo asset (for cross-device photo matching via iCloud Photo Library)
    /// - Parameter asset: The PHAsset to get the cloud identifier for
    /// - Returns: The cloud identifier string, or nil if not available
    static func cloudIdentifier(for asset: PHAsset) -> String? {
        cloudIdentifier(forLocalIdentifier: asset.localIdentifier)
    }

    /// Get the cloud identifier for a local identifier string
    /// - Parameter localIdentifier: The local identifier of the asset
    /// - Returns: The cloud identifier string, or nil if not available
    static func cloudIdentifier(forLocalIdentifier localIdentifier: String) -> String? {
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [localIdentifier])

        guard let mapping = mappings[localIdentifier] else {
            return nil
        }

        switch mapping {
        case .success(let cloudId):
            return cloudId.stringValue
        case .failure:
            return nil
        }
    }
}
