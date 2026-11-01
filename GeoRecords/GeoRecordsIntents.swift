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

// MARK: - Region Entity

enum RegionEntityKind: String, Codable, Sendable {
    case state, country, continent

    var noun: String { rawValue }
}

/// A state, country or continent Siri can ask about ("Have I been to Nevada?").
/// Built from the app's fixed lists (no GeoJSON parse), plus any visited country
/// outside the 195 (Taiwan, Kosovo) so an answer is never "unknown place".
struct RegionEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Region")
    static let defaultQuery = RegionEntityQuery()

    let id: String        // "state:NV", "country:JP", "continent:Asia"
    let name: String
    let kind: RegionEntityKind
    let code: String      // the record row's code: "US-NV", "JP", "Asia"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    nonisolated static func all(extraCountries: [(code: String, name: String)] = []) -> [RegionEntity] {
        var result: [RegionEntity] = []
        for (postal, name) in usStateNames.sorted(by: { $0.value < $1.value }) {
            result.append(RegionEntity(id: "state:\(postal)", name: name, kind: .state, code: "US-\(postal)"))
        }
        var seenCountries = Set<String>()
        for country in unMemberAndObserverCountries + extraCountries where seenCountries.insert(country.code).inserted {
            result.append(RegionEntity(id: "country:\(country.code)", name: country.name, kind: .country, code: country.code))
        }
        for continent in Continent.allCases {
            result.append(RegionEntity(id: "continent:\(continent.rawValue)", name: continent.rawValue,
                                       kind: .continent, code: continent.rawValue))
        }
        return result
    }

    /// Exact name matches first; otherwise prefix and substring matches
    nonisolated static func matching(_ string: String, in entities: [RegionEntity]) -> [RegionEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let exact = entities.filter { $0.name.lowercased() == query }
        if !exact.isEmpty { return exact }
        return entities.filter { $0.name.lowercased().contains(query) }
    }
}

struct RegionEntityQuery: EntityStringQuery {
    @MainActor
    private func allEntities() -> [RegionEntity] {
        let extras = RegionTrackingManager.shared.visitedCountries.compactMap { detail -> (code: String, name: String)? in
            guard let code = detail.regionCode, let name = detail.locationName else { return nil }
            return (code, name)
        }
        return RegionEntity.all(extraCountries: extras)
    }

    func entities(for identifiers: [String]) async throws -> [RegionEntity] {
        let all = await allEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [RegionEntity] {
        RegionEntity.matching(string, in: await allEntities())
    }

    func suggestedEntities() async throws -> [RegionEntity] {
        await allEntities()
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
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let typeName = recordType.recordType.rawValue

        guard let detail = RecordManager.shared.getRecord(type: typeName, timeFrame: timeFrame.timeFrame) else {
            let dialog = Self.missingRecordDialog(timeFrame: timeFrame, typeName: typeName)
            return .result(value: "", dialog: IntentDialog(stringLiteral: dialog))
        }

        let unitSystem = SettingsManager.shared.unitSystem
        let spoken = FormatUtils.spokenValue(detail.value, recordType: typeName, unitSystem: unitSystem)
        let date = detail.timestamp.formatted(date: .abbreviated, time: .omitted)
        let dialog = Self.recordDialog(timeFrame: timeFrame, typeName: typeName, value: spoken,
                                       locationName: detail.locationName, date: date)
        // Shortcuts get the display form ("69.6492° N"); Siri says the spoken one
        return .result(value: detail.formattedValue(unitSystem: unitSystem), dialog: IntentDialog(stringLiteral: dialog))
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

/// "Have I been to Nevada?"
struct VisitedRegionQueryIntent: AppIntent {
    static let title: LocalizedStringResource = "Have I Been To"
    static let description = IntentDescription("Tells you whether you've visited a state, country or continent, and how often.")

    @Parameter(title: "Region")
    var region: RegionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Have I been to \(\.$region)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let manager = RegionTrackingManager.shared
        let recordType: RecordType
        let visited: [RecordDetail]
        let total: Int
        switch region.kind {
        case .state: (recordType, visited, total) = (.state, manager.visitedStates, manager.stateCount)
        case .country: (recordType, visited, total) = (.country, manager.visitedCountries, manager.countryCount)
        case .continent: (recordType, visited, total) = (.continent, manager.visitedContinents, manager.continentCount)
        }

        let match = visited.first { detail in
            let code = normalizeRegionCode(detail.regionCode ?? "", isState: region.kind == .state)
            return code == region.code || detail.locationName == region.name
        }

        if let match {
            let summary = manager.visitSummary(code: region.code, type: recordType)
            let dialog = Self.visitedDialog(name: region.name, firstVisit: match.timestamp, count: max(summary.count, 1))
            return .result(value: true, dialog: IntentDialog(stringLiteral: dialog))
        }
        let dialog = Self.notVisitedDialog(name: region.name, kindName: region.kind.noun, nextCount: total + 1)
        return .result(value: false, dialog: IntentDialog(stringLiteral: dialog))
    }

    static func visitedDialog(name: String, firstVisit: Date, count: Int) -> String {
        let when = firstVisit.formatted(.dateTime.month(.wide).year())
        if count <= 1 { return "Yes. You visited \(name) in \(when)." }
        return "Yes. You first visited \(name) in \(when) and you've been there \(count) times."
    }

    static func notVisitedDialog(name: String, kindName: String, nextCount: Int) -> String {
        "Not yet. \(name) would be your \(ordinal(nextCount)) \(kindName)."
    }

    private static func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)."
    }
}

// MARK: - App Shortcuts

/// Phrases surfaced in Siri, Shortcuts, and Spotlight. A phrase carries at most
/// one parameter, so the record and timeframe variants are separate phrases.
struct GeoRecordsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetRecordIntent(),
            phrases: [
                "Get my record from \(.applicationName)",
                "What's my record in \(.applicationName)",
                "What's my \(\.$recordType) in \(.applicationName)",
                "Get my \(\.$recordType) record from \(.applicationName)",
                "What's my \(\.$timeFrame) record in \(.applicationName)"
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
        AppShortcut(
            intent: VisitedRegionQueryIntent(),
            phrases: [
                "Have I been to \(\.$region) in \(.applicationName)",
                "Did I visit \(\.$region) in \(.applicationName)"
            ],
            shortTitle: "Have I Been To",
            systemImageName: "mappin.and.ellipse"
        )
    }
}
