import AppIntents
import Foundation

// MARK: - Intent Parameter Enums

/// Record type choices exposed to Siri/Shortcuts.
/// Mirrors the geographic-extreme cases of RecordType (region visits aren't queryable records).
enum RecordQueryType: String, AppEnum {
    case north
    case south
    case east
    case west
    case up
    case fromHome

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Record Type")
    static let caseDisplayRepresentations: [RecordQueryType: DisplayRepresentation] = [
        .north: "Furthest North",
        .south: "Furthest South",
        .east: "Furthest East",
        .west: "Furthest West",
        .up: "Furthest Up",
        .fromHome: "Furthest from Home"
    ]

    var recordType: RecordType {
        switch self {
        case .north: return .north
        case .south: return .south
        case .east: return .east
        case .west: return .west
        case .up: return .up
        case .fromHome: return .fromHome
        }
    }
}

/// Timeframe choices exposed to Siri/Shortcuts
enum RecordQueryTimeFrame: String, AppEnum {
    case month
    case year
    case lifetime

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Timeframe")
    static let caseDisplayRepresentations: [RecordQueryTimeFrame: DisplayRepresentation] = [
        .month: "This Month",
        .year: "This Year",
        .lifetime: "Lifetime"
    ]

    var timeFrame: TimeFrame {
        switch self {
        case .month: return .month
        case .year: return .year
        case .lifetime: return .allTime
        }
    }

}

// MARK: - Intents

/// "What's my furthest north this year?"
struct GetRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a Record"
    static let description = IntentDescription("Gets one of your geographic records, like your furthest north this year.")

    @Parameter(title: "Record")
    var recordType: RecordQueryType

    @Parameter(title: "Timeframe", default: .lifetime)
    var timeFrame: RecordQueryTimeFrame

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$timeFrame) \(\.$recordType) record")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let typeName = recordType.recordType.rawValue

        guard let detail = RecordManager.shared.getRecord(type: typeName, timeFrame: timeFrame.timeFrame) else {
            return .result(dialog: IntentDialog(stringLiteral: Self.missingRecordDialog(timeFrame: timeFrame, typeName: typeName)))
        }

        let value = detail.formattedValue(unitSystem: SettingsManager.shared.unitSystem)
        let date = detail.timestamp.formatted(date: .abbreviated, time: .omitted)
        let dialog = Self.recordDialog(timeFrame: timeFrame, typeName: typeName, value: value,
                                       locationName: detail.locationName, date: date)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    // MARK: Spoken phrasing

    /// "Furthest North record for this month" / "lifetime Furthest North record":
    /// the qualifier goes where English puts it, so Siri never reads
    /// "a this month's Furthest North record".
    private static func qualifiedRecordName(timeFrame: RecordQueryTimeFrame, typeName: String) -> String {
        switch timeFrame {
        case .month: return "\(typeName) record for this month"
        case .year: return "\(typeName) record for this year"
        case .lifetime: return "lifetime \(typeName) record"
        }
    }

    static func missingRecordDialog(timeFrame: RecordQueryTimeFrame, typeName: String) -> String {
        "You don't have a \(qualifiedRecordName(timeFrame: timeFrame, typeName: typeName)) yet."
    }

    static func recordDialog(timeFrame: RecordQueryTimeFrame, typeName: String, value: String,
                             locationName: String?, date: String) -> String {
        // Geocoding stores "" while throttled; an empty name must not read as "at ,"
        let place: String
        if let name = locationName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            place = " at \(name)"
        } else {
            place = ""
        }
        return "Your \(qualifiedRecordName(timeFrame: timeFrame, typeName: typeName)) is \(value)\(place), set \(date)."
    }
}

/// "How many states have I visited?"
struct GetRegionCountsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Region Counts"
    static let description = IntentDescription("Tells you how many states, countries, and continents you've visited.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let regions = RegionTrackingManager.shared
        return .result(dialog: "You've visited \(regions.stateCount) of 50 states, \(regions.countryCount) countries, and \(regions.continentCount) of 7 continents.")
    }
}

// MARK: - App Shortcuts

/// Phrases surfaced in Siri, Shortcuts, and Spotlight
struct GeoRecordsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetRecordIntent(),
            phrases: [
                "Get my record from \(.applicationName)",
                "What's my record in \(.applicationName)"
            ],
            shortTitle: "Get a Record",
            systemImageName: "location.north.fill"
        )
        AppShortcut(
            intent: GetRegionCountsIntent(),
            phrases: [
                "How many states have I visited in \(.applicationName)",
                "Get my region counts from \(.applicationName)"
            ],
            shortTitle: "Region Counts",
            systemImageName: "map.fill"
        )
    }
}
