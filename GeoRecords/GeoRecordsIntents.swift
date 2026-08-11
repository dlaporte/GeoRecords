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

    /// How the timeframe reads inside a spoken sentence
    var spokenName: String {
        switch self {
        case .month: return "this month's"
        case .year: return "this year's"
        case .lifetime: return "lifetime"
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
            return .result(dialog: "You don't have a \(timeFrame.spokenName) \(typeName) record yet.")
        }

        let value = detail.formattedValue(unitSystem: SettingsManager.shared.unitSystem)
        let place = detail.locationName.map { " at \($0)" } ?? ""
        let date = detail.timestamp.formatted(date: .abbreviated, time: .omitted)
        return .result(dialog: "Your \(timeFrame.spokenName) \(typeName) record is \(value)\(place), set \(date).")
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
