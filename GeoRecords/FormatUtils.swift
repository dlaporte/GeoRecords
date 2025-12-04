import SwiftUI

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
                let feet = value * 3.28084
                return String(format: "%.0f ft", feet)
            } else {
                return String(format: "%.0f m", value)
            }

        case "Furthest from Home":
            // Value is stored in feet
            if unitSystem == .imperial {
                let miles = value / 5280.0
                return String(format: "%.2f mi", miles)
            } else {
                let meters = value / 3.28084
                let km = meters / 1000.0
                return String(format: "%.2f km", km)
            }

        default:
            return "\(value)"
        }
    }
}
