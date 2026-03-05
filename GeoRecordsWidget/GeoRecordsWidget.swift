//
//  GeoRecordsWidget.swift
//  GeoRecordsWidget
//
//  Created by David LaPorte on 12/12/25.
//

import WidgetKit
import SwiftUI
import CoreData
import AppIntents
import ImageIO
import CoreLocation
import UIKit

// MARK: - Constants

/// Conversion constants for unit display
private enum UnitConversion {
    static let metersToFeet = 3.28084
    static let metersToMiles = 1.0 / 1609.344
    static let metersToKilometers = 1.0 / 1000.0
}

/// Shared value formatter for widget display
// MARK: - Locale-Aware Number Formatting

private let wholeNumberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    formatter.minimumFractionDigits = 0
    return formatter
}()

private let twoDecimalFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 2
    return formatter
}()

private func formatWholeNumber(_ value: Double) -> String {
    wholeNumberFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
}

private func formatTwoDecimal(_ value: Double) -> String {
    twoDecimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
}

private func formatRecordValue(_ value: Double, recordType: String, unitSystem: String) -> String {
    guard let type = WidgetRecordType.from(string: recordType) else {
        return "\(value)"
    }

    switch type {
    case .north, .south, .east, .west:
        return String(format: "%.4f°", value)
    case .up:
        if unitSystem == "imperial" {
            return "\(formatWholeNumber(value * UnitConversion.metersToFeet)) ft"
        } else {
            return "\(formatWholeNumber(value)) m"
        }
    case .fromHome:
        if unitSystem == "imperial" {
            return "\(formatTwoDecimal(value * UnitConversion.metersToMiles)) mi"
        } else {
            return "\(formatTwoDecimal(value * UnitConversion.metersToKilometers)) km"
        }
    }
}

// MARK: - Shared Constants

/// App group identifier for shared data access
private let appGroupIdentifier = "group.com.georecords.shared"

/// Widget refresh interval in hours
private let widgetRefreshIntervalHours = 1

// Note: lifetimeTimeFrameVariations is defined in Constants.swift (shared with widget)

/// Standard record order using WidgetRecordType enum, sorted by sortOrder
let standardRecordOrder = WidgetRecordType.allCases.sorted { $0.sortOrder < $1.sortOrder }.map { $0.rawValue }

// MARK: - Shared Core Data Access

/// Creates and configures a Core Data container for widget read-only access
/// - Parameter completion: Called with the loaded context or nil on error
private func loadWidgetCoreData(completion: @escaping (NSManagedObjectContext?) -> Void) {
    guard let appGroupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) else {
        completion(nil)
        return
    }

    let storeURL = appGroupURL.appendingPathComponent("GeoRecordsModel.sqlite")

    // Check if database file exists - widget can't create it (read-only)
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
        print("Widget: Database not created yet - open the main app first")
        completion(nil)
        return
    }

    let container = NSPersistentContainer(name: "GeoRecordsModel")
    let storeDescription = NSPersistentStoreDescription(url: storeURL)

    // Must match main app's settings to avoid read-only mode
    storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
    storeDescription.isReadOnly = true  // Widget only reads data

    container.persistentStoreDescriptions = [storeDescription]

    container.loadPersistentStores { _, error in
        if let error = error {
            print("Widget: Failed to load Core Data: \(error)")
            completion(nil)
            return
        }
        completion(container.viewContext)
    }
}

/// Gets the user's unit system preference from shared UserDefaults
private func getUnitSystem() -> String {
    let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)
    let unitSystemString = sharedDefaults?.string(forKey: "unitSystem") ?? "imperial"
    return unitSystemString == "metric" ? "metric" : "imperial"
}

/// Gets the user's home coordinate from shared UserDefaults
/// Returns nil if no home is set
private func getHomeCoordinate() -> CLLocationCoordinate2D? {
    let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)
    guard let lat = sharedDefaults?.object(forKey: "homeLatitude") as? Double,
          let lon = sharedDefaults?.object(forKey: "homeLongitude") as? Double else {
        return nil
    }
    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    guard CLLocationCoordinate2DIsValid(coord) else { return nil }
    return coord
}

/// Threshold for filtering out records at home (in meters)
private let widgetAtHomeRadiusMeters: Double = 100.0

/// Gets the timeFrame field values and date range for filtering records
/// This matches the logic in the main app's RecordHistoryManager.getFurthestRecord()
/// - Parameter timeFrame: The widget time frame selection
/// - Returns: Tuple of (timeFrame field values to match, start date, end date)
private func timeFrameFilter(for timeFrame: WidgetTimeFrame) -> (timeFrameValues: [String], startDate: Date, endDate: Date) {
    let calendar = Calendar.current
    let now = Date()

    switch timeFrame {
    case .month:
        // Monthly records only, within current month
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now
        return (["Monthly"], monthStart, monthEnd)

    case .year:
        // Yearly AND Monthly records within current year (Monthly is part of this year)
        let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
        let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart) ?? now
        return (["Yearly", "Monthly"], yearStart, yearEnd)

    case .allTime:
        // Lifetime records only (handles all historical variations)
        return (lifetimeTimeFrameVariations, Date.distantPast, Date.distantFuture)
    }
}

// MARK: - App Intent Configuration

/// Record type enum for widget configuration.
/// IMPORTANT: This is a duplicate of RecordType in Constants.swift (main app).
/// The rawValue strings MUST match exactly for data sharing to work correctly.
/// When adding/removing cases, update BOTH enums to stay in sync.
enum WidgetRecordType: String, CaseIterable, Codable, AppEnum {
    case north = "Furthest North"
    case south = "Furthest South"
    case east = "Furthest East"
    case west = "Furthest West"
    case up = "Furthest Up"
    case fromHome = "Furthest from Home"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Record Type"

    static var caseDisplayRepresentations: [WidgetRecordType: DisplayRepresentation] = [
        .north: DisplayRepresentation(title: "North", image: .init(systemName: "arrow.up.circle.fill")),
        .south: DisplayRepresentation(title: "South", image: .init(systemName: "arrow.down.circle.fill")),
        .east: DisplayRepresentation(title: "East", image: .init(systemName: "arrow.right.circle.fill")),
        .west: DisplayRepresentation(title: "West", image: .init(systemName: "arrow.left.circle.fill")),
        .up: DisplayRepresentation(title: "Up (Altitude)", image: .init(systemName: "mountain.2.fill")),
        .fromHome: DisplayRepresentation(title: "From Home", image: .init(systemName: "house.circle.fill"))
    ]

    /// Sort order index for consistent ordering
    var sortOrder: Int {
        switch self {
        case .north: return 0
        case .south: return 1
        case .up: return 2
        case .west: return 3
        case .east: return 4
        case .fromHome: return 5
        }
    }

    /// Whether higher values are better (true) or lower values are better (false)
    var isAscending: Bool {
        switch self {
        case .north, .east, .up, .fromHome: return true
        case .south, .west: return false
        }
    }

    /// Get record type from string
    static func from(string: String) -> WidgetRecordType? {
        return WidgetRecordType.allCases.first { $0.rawValue == string }
    }

    /// Short display name
    var shortName: String {
        switch self {
        case .north: return "North"
        case .south: return "South"
        case .east: return "East"
        case .west: return "West"
        case .up: return "Up"
        case .fromHome: return "From Home"
        }
    }

    /// SF Symbol icon name
    var iconName: String {
        switch self {
        case .north: return "arrow.up.circle.fill"
        case .south: return "arrow.down.circle.fill"
        case .east: return "arrow.right.circle.fill"
        case .west: return "arrow.left.circle.fill"
        case .up: return "mountain.2.fill"
        case .fromHome: return "house.circle.fill"
        }
    }

    /// Display color
    var color: Color {
        switch self {
        case .north: return .blue
        case .south: return .cyan
        case .east: return .orange
        case .west: return .purple
        case .up: return .green
        case .fromHome: return .red
        }
    }
}

/// Time frame enum for widget configuration.
/// IMPORTANT: This is a duplicate of TimeFrame in Constants.swift (main app).
/// The rawValue strings MUST match exactly for data sharing to work correctly.
/// When adding/removing cases, update BOTH enums to stay in sync.
enum WidgetTimeFrame: String, CaseIterable, Codable, AppEnum {
    case allTime = "Lifetime"
    case year = "This Year"   // Maps to TimeFrame.year ("Yearly") - display differs but semantics match
    case month = "This Month" // Maps to TimeFrame.month ("Monthly") - display differs but semantics match

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Time Frame"

    static var caseDisplayRepresentations: [WidgetTimeFrame: DisplayRepresentation] = [
        .allTime: DisplayRepresentation(title: "Lifetime"),
        .year: DisplayRepresentation(title: "This Year"),
        .month: DisplayRepresentation(title: "This Month")
    ]

    /// URL parameter value for deep links (must match TimeFrame.init(deepLinkParam:) in main app)
    var deepLinkParam: String {
        switch self {
        case .month: return "monthly"
        case .year: return "yearly"
        case .allTime: return "allTime"
        }
    }
}

struct GeoRecordsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configure Widget"
    static var description: IntentDescription = "Choose which records to display"

    @Parameter(title: "Records to Show", default: [.north, .south, .east, .west, .up, .fromHome])
    var selectedRecords: [WidgetRecordType]

    @Parameter(title: "Time Frame", default: .allTime)
    var timeFrame: WidgetTimeFrame

    init() {}

    init(selectedRecords: [WidgetRecordType], timeFrame: WidgetTimeFrame = .allTime) {
        self.selectedRecords = selectedRecords
        self.timeFrame = timeFrame
    }
}

// MARK: - Widget Data Model

struct WidgetRecordData {
    let type: String
    let value: String
    let location: String
    let timestamp: Date

    static let placeholder = WidgetRecordData(
        type: "Furthest North",
        value: "No records yet",
        location: "Start exploring!",
        timestamp: Date()
    )

    /// Sort order based on standard record order
    var sortOrder: Int {
        standardRecordOrder.firstIndex(of: type) ?? 999
    }
}

// MARK: - Timeline Entry

struct RecordsEntry: TimelineEntry {
    let date: Date
    let records: [WidgetRecordData]
    let configuration: GeoRecordsWidgetIntent
}

// MARK: - Timeline Provider

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RecordsEntry {
        RecordsEntry(
            date: Date(),
            records: [WidgetRecordData.placeholder],
            configuration: GeoRecordsWidgetIntent()
        )
    }

    func snapshot(for configuration: GeoRecordsWidgetIntent, in context: Context) async -> RecordsEntry {
        RecordsEntry(
            date: Date(),
            records: fetchRecords(for: configuration),
            configuration: configuration
        )
    }

    func timeline(for configuration: GeoRecordsWidgetIntent, in context: Context) async -> Timeline<RecordsEntry> {
        let currentDate = Date()
        let records = fetchRecords(for: configuration)

        // Create an entry for now
        let entry = RecordsEntry(date: currentDate, records: records, configuration: configuration)

        // Refresh every hour
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: widgetRefreshIntervalHours, to: currentDate)
            ?? currentDate.addingTimeInterval(3600)  // Fallback: 1 hour from now
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    // MARK: - Data Fetching

    private func fetchRecords(for configuration: GeoRecordsWidgetIntent) -> [WidgetRecordData] {
        let selectedTypes = Set(configuration.selectedRecords.map { $0.rawValue })
        let timeFrame = configuration.timeFrame

        var records: [WidgetRecordData] = []
        let semaphore = DispatchSemaphore(value: 0)

        loadWidgetCoreData { context in
            defer { semaphore.signal() }

            guard let context = context else { return }

            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "RecordHistoryEntry")
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

            do {
                guard let entries = try context.fetch(request) as? [NSManagedObject] else { return }

                let unitSystem = getUnitSystem()
                let filter = timeFrameFilter(for: timeFrame)
                let homeCoord = getHomeCoordinate()
                let homeLocation: CLLocation? = homeCoord.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }

                // Filter entries by timeFrame field AND timestamp range (matching main app logic)
                let filteredEntries = entries.filter { entry in
                    // Must have valid timeFrame field that matches our filter
                    guard let entryTimeFrame = entry.value(forKey: "timeFrame") as? String else { return false }
                    guard filter.timeFrameValues.contains(entryTimeFrame) else { return false }

                    // Must be within date range
                    guard let timestamp = entry.value(forKey: "timestamp") as? Date else { return false }
                    guard timestamp >= filter.startDate && timestamp < filter.endDate else { return false }

                    // Filter out records at home
                    if let home = homeLocation,
                       let lat = entry.value(forKey: "latitude") as? Double,
                       let lon = entry.value(forKey: "longitude") as? Double {
                        let entryLocation = CLLocation(latitude: lat, longitude: lon)
                        if entryLocation.distance(from: home) <= widgetAtHomeRadiusMeters {
                            return false
                        }
                    }

                    return true
                }

                // Group by record type and get the most extreme for each
                var latestByType: [String: NSManagedObject] = [:]

                for entry in filteredEntries {
                    guard let type = entry.value(forKey: "recordType") as? String else { continue }

                    // Only include selected record types
                    guard selectedTypes.contains(type) else { continue }

                    // Keep the most extreme value for each type
                    if let existing = latestByType[type],
                       let existingValue = existing.value(forKey: "value") as? Double,
                       let newValue = entry.value(forKey: "value") as? Double {

                        let shouldReplace: Bool
                        if let widgetType = WidgetRecordType.from(string: type) {
                            shouldReplace = widgetType.isAscending ? newValue > existingValue : newValue < existingValue
                        } else {
                            shouldReplace = false
                        }

                        if shouldReplace {
                            latestByType[type] = entry
                        }
                    } else {
                        latestByType[type] = entry
                    }
                }

                // Convert to widget data and sort by standard order
                records = latestByType.values.compactMap { entry -> WidgetRecordData? in
                    guard let type = entry.value(forKey: "recordType") as? String,
                          let value = entry.value(forKey: "value") as? Double,
                          let timestamp = entry.value(forKey: "timestamp") as? Date else {
                        return nil
                    }

                    let location = entry.value(forKey: "locationName") as? String ?? "Unknown"
                    let formattedValue = formatRecordValue(value, recordType: type, unitSystem: unitSystem)

                    return WidgetRecordData(
                        type: type,
                        value: formattedValue,
                        location: location,
                        timestamp: timestamp
                    )
                }.sorted { $0.sortOrder < $1.sortOrder }

            } catch {
                print("Widget: Failed to fetch records: \(error)")
            }
        }

        semaphore.wait()

        return records.isEmpty ? [WidgetRecordData.placeholder] : records
    }
}

// MARK: - Widget View

struct GeoRecordsWidgetEntryView : View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    private var timeFrame: WidgetTimeFrame {
        entry.configuration.timeFrame
    }

    var body: some View {
        VStack(spacing: 0) {
            if family == .systemMedium {
                // Medium widget: 2x3 grid with timeframe
                MediumWidgetGridView(records: entry.records, timeFrame: timeFrame)
            } else {
                // Small widget: compact list
                SmallWidgetListView(records: entry.records, timeFrame: timeFrame)
            }
        }
        .widgetURL(deepLinkURL)
    }

    private var deepLinkURL: URL? {
        URL(string: "georecords://records?timeframe=\(timeFrame.deepLinkParam)")
    }
}

// MARK: - Medium Widget Grid View

struct MediumWidgetGridView: View {
    let records: [WidgetRecordData]
    let timeFrame: WidgetTimeFrame

    var body: some View {
        VStack(spacing: 4) {
            // Timeframe indicator in top-right
            HStack {
                Spacer()
                Text(timeFrame.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            // 2x3 grid of records
            let recordsToShow = min(6, records.count)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 4) {
                ForEach(0..<recordsToShow, id: \.self) { index in
                    RecordGridCell(record: records[index])
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
    }
}

struct RecordGridCell: View {
    let record: WidgetRecordData

    private var recordType: WidgetRecordType? {
        WidgetRecordType.from(string: record.type)
    }

    /// Split location into two lines after the second comma
    private var locationLines: (line1: String, line2: String?) {
        let parts = record.location.components(separatedBy: ", ")
        if parts.count >= 3 {
            let line1 = parts[0..<2].joined(separator: ", ")
            let line2 = parts[2...].joined(separator: ", ")
            return (line1, line2)
        } else {
            return (record.location, nil)
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            // Icon
            Image(systemName: recordType?.iconName ?? "location.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(recordType?.color ?? .gray)

            // Value
            Text(record.value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(recordType?.color ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // Location - split into two centered lines
            VStack(spacing: 0) {
                Text(locationLines.line1)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let line2 = locationLines.line2 {
                    Text(line2)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Small Widget Grid View

struct SmallWidgetListView: View {
    let records: [WidgetRecordData]
    let timeFrame: WidgetTimeFrame

    var body: some View {
        VStack(spacing: 4) {
            // Timeframe indicator in top-right
            HStack {
                Spacer()
                Text(timeFrame.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )
            }

            // 2x2 grid of records
            let recordsToShow = min(4, records.count)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(0..<recordsToShow, id: \.self) { index in
                    SmallRecordGridCell(record: records[index])
                }
            }

            Spacer(minLength: 0)
        }
        .padding(2)
    }
}

struct SmallRecordGridCell: View {
    let record: WidgetRecordData

    private var recordType: WidgetRecordType? {
        WidgetRecordType.from(string: record.type)
    }

    var body: some View {
        VStack(spacing: 4) {
            // Icon
            Image(systemName: recordType?.iconName ?? "location.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(recordType?.color ?? .gray)

            // Value
            Text(record.value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(recordType?.color ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Widget Configuration

struct GeoRecordsWidget: Widget {
    let kind: String = "GeoRecordsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: GeoRecordsWidgetIntent.self, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                GeoRecordsWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                GeoRecordsWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Records List")
        .description("View multiple geographical records at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Single Record Widget (with Photo)

/// Intent for single record widget configuration
struct SingleRecordWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configure Record"
    static var description: IntentDescription = "Choose which record to display"

    @Parameter(title: "Record", default: .north)
    var selectedRecord: WidgetRecordType

    @Parameter(title: "Time Frame", default: .allTime)
    var timeFrame: WidgetTimeFrame

    init() {}

    init(selectedRecord: WidgetRecordType, timeFrame: WidgetTimeFrame = .allTime) {
        self.selectedRecord = selectedRecord
        self.timeFrame = timeFrame
    }
}

/// Data model for single record with photo
struct SingleRecordData {
    let type: String
    let value: String
    let location: String
    let timestamp: Date
    let thumbnailImage: UIImage?  // Pre-resized thumbnail, not raw data

    static let placeholder = SingleRecordData(
        type: "Furthest North",
        value: "—",
        location: "No record yet",
        timestamp: Date(),
        thumbnailImage: nil
    )
}

/// Timeline entry for single record widget
struct SingleRecordEntry: TimelineEntry {
    let date: Date
    let record: SingleRecordData
    let configuration: SingleRecordWidgetIntent
}

/// Provider for single record widget
struct SingleRecordProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SingleRecordEntry {
        SingleRecordEntry(
            date: Date(),
            record: SingleRecordData.placeholder,
            configuration: SingleRecordWidgetIntent()
        )
    }

    func snapshot(for configuration: SingleRecordWidgetIntent, in context: Context) async -> SingleRecordEntry {
        SingleRecordEntry(
            date: Date(),
            record: fetchRecord(for: configuration),
            configuration: configuration
        )
    }

    func timeline(for configuration: SingleRecordWidgetIntent, in context: Context) async -> Timeline<SingleRecordEntry> {
        let currentDate = Date()
        let record = fetchRecord(for: configuration)
        let entry = SingleRecordEntry(date: currentDate, record: record, configuration: configuration)
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: widgetRefreshIntervalHours, to: currentDate)
            ?? currentDate.addingTimeInterval(3600)  // Fallback: 1 hour from now
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func fetchRecord(for configuration: SingleRecordWidgetIntent) -> SingleRecordData {
        let recordType = configuration.selectedRecord.rawValue
        let timeFrame = configuration.timeFrame

        var result: SingleRecordData = SingleRecordData.placeholder
        let semaphore = DispatchSemaphore(value: 0)

        loadWidgetCoreData { context in
            defer { semaphore.signal() }

            guard let context = context else { return }

            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "RecordHistoryEntry")
            request.predicate = NSPredicate(format: "recordType == %@", recordType)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

            do {
                guard let entries = try context.fetch(request) as? [NSManagedObject] else { return }

                let unitSystem = getUnitSystem()
                let filter = timeFrameFilter(for: timeFrame)
                let homeCoord = getHomeCoordinate()
                let homeLocation: CLLocation? = homeCoord.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }

                // Filter by timeFrame field AND timestamp range (matching main app logic)
                let filteredEntries = entries.filter { entry in
                    // Must have valid timeFrame field that matches our filter
                    guard let entryTimeFrame = entry.value(forKey: "timeFrame") as? String else { return false }
                    guard filter.timeFrameValues.contains(entryTimeFrame) else { return false }

                    // Must be within date range
                    guard let timestamp = entry.value(forKey: "timestamp") as? Date else { return false }
                    guard timestamp >= filter.startDate && timestamp < filter.endDate else { return false }

                    // Filter out records at home
                    if let home = homeLocation,
                       let lat = entry.value(forKey: "latitude") as? Double,
                       let lon = entry.value(forKey: "longitude") as? Double {
                        let entryLocation = CLLocation(latitude: lat, longitude: lon)
                        if entryLocation.distance(from: home) <= widgetAtHomeRadiusMeters {
                            return false
                        }
                    }

                    return true
                }

                var bestEntry: NSManagedObject?
                for entry in filteredEntries {
                    guard let newValue = entry.value(forKey: "value") as? Double else { continue }

                    if let existing = bestEntry,
                       let existingValue = existing.value(forKey: "value") as? Double {
                        let shouldReplace: Bool
                        if let widgetType = WidgetRecordType.from(string: recordType) {
                            shouldReplace = widgetType.isAscending ? newValue > existingValue : newValue < existingValue
                        } else {
                            shouldReplace = false
                        }
                        if shouldReplace {
                            bestEntry = entry
                        }
                    } else {
                        bestEntry = entry
                    }
                }

                if let entry = bestEntry,
                   let value = entry.value(forKey: "value") as? Double,
                   let timestamp = entry.value(forKey: "timestamp") as? Date {

                    let location = entry.value(forKey: "locationName") as? String ?? "Unknown"
                    let formattedValue = formatRecordValue(value, recordType: recordType, unitSystem: unitSystem)

                    // Load thumbnail from app group cache
                    var thumbnail: UIImage?
                    if let recordId = entry.value(forKey: "id") as? UUID {
                        thumbnail = self.loadThumbnailFromCache(for: recordId)
                    }
                    // Fallback to legacy embedded photo data
                    if thumbnail == nil, let photoData = entry.value(forKey: "photoData") as? Data {
                        thumbnail = self.createThumbnailFromData(photoData, maxSize: 300)
                    }

                    result = SingleRecordData(
                        type: recordType,
                        value: formattedValue,
                        location: location,
                        timestamp: timestamp,
                        thumbnailImage: thumbnail
                    )
                }

            } catch {
                print("Widget: Failed to fetch record: \(error)")
            }
        }

        semaphore.wait()
        return result
    }

    /// Create a small thumbnail using ImageIO - much more memory efficient
    /// This avoids loading the full image into memory
    private func createThumbnailFromData(_ data: Data, maxSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    /// Load a cached thumbnail from the app group
    private func loadThumbnailFromCache(for recordId: UUID) -> UIImage? {
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }

        let thumbnailURL = appGroupURL
            .appendingPathComponent("Thumbnails")
            .appendingPathComponent("\(recordId.uuidString).jpg")

        guard FileManager.default.fileExists(atPath: thumbnailURL.path),
              let data = try? Data(contentsOf: thumbnailURL),
              let image = UIImage(data: data) else {
            return nil
        }

        return image
    }
}

/// View for single record widget content (text overlay)
struct SingleRecordContentView: View {
    let record: SingleRecordData
    let hasPhoto: Bool
    let timeFrame: WidgetTimeFrame

    private var recordType: WidgetRecordType? {
        WidgetRecordType.from(string: record.type)
    }

    private func shadowModifier() -> some ViewModifier {
        TextShadowModifier(isEnabled: hasPhoto)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: icon left, timeframe right
            HStack {
                Image(systemName: recordType?.iconName ?? "location.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(hasPhoto ? .white : (recordType?.color ?? .gray))
                    .modifier(shadowModifier())

                Spacer()

                // Timeframe indicator
                Text(timeFrame.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(hasPhoto ? .white.opacity(0.8) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(hasPhoto ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                    )
                    .modifier(shadowModifier())
            }

            Spacer()

            // Bottom content - centered
            VStack(spacing: 2) {
                // Value
                Text(record.value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(hasPhoto ? .white : (recordType?.color ?? .gray))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .modifier(shadowModifier())

                // Location
                Text(record.location)
                    .font(.system(size: 13))
                    .foregroundColor(hasPhoto ? .white.opacity(0.95) : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .modifier(shadowModifier())

                // Date
                Text(record.timestamp, style: .date)
                    .font(.system(size: 11))
                    .foregroundColor(hasPhoto ? .white.opacity(0.7) : .secondary.opacity(0.7))
                    .modifier(shadowModifier())
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 0)
        .widgetURL(deepLinkURL)
    }

    private var deepLinkURL: URL? {
        URL(string: "georecords://records?timeframe=\(timeFrame.deepLinkParam)")
    }
}

/// Modifier that adds shadow only when enabled (for photo backgrounds)
struct TextShadowModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        } else {
            content
        }
    }
}

/// Background view for single record widget (photo + gradient)
struct SingleRecordBackgroundView: View {
    let thumbnail: UIImage

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    // Subtle gradient overlay for text readability
                    LinearGradient(
                        colors: [.black.opacity(0.45), .black.opacity(0.15), .black.opacity(0.5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
    }
}

/// Single record widget configuration
struct SingleRecordWidget: Widget {
    let kind: String = "SingleRecordWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SingleRecordWidgetIntent.self, provider: SingleRecordProvider()) { entry in
            let hasPhoto = entry.record.thumbnailImage != nil
            let timeFrame = entry.configuration.timeFrame

            if #available(iOS 17.0, *) {
                SingleRecordContentView(record: entry.record, hasPhoto: hasPhoto, timeFrame: timeFrame)
                    .containerBackground(for: .widget) {
                        if let thumbnail = entry.record.thumbnailImage {
                            SingleRecordBackgroundView(thumbnail: thumbnail)
                        } else {
                            Color(.systemBackground).opacity(0.8)
                        }
                    }
            } else {
                ZStack {
                    if let thumbnail = entry.record.thumbnailImage {
                        SingleRecordBackgroundView(thumbnail: thumbnail)
                    }
                    SingleRecordContentView(record: entry.record, hasPhoto: hasPhoto, timeFrame: timeFrame)
                }
                .padding()
                .background()
            }
        }
        .configurationDisplayName("Single Record")
        .description("Display one record with its photo.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Region Statistics Widget (Large)

/// Region type for statistics widget configuration
enum WidgetRegionDisplayType: String, CaseIterable, Codable, AppEnum {
    case states = "States"
    case countries = "Countries"
    case continents = "Continents"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Region Type"

    static var caseDisplayRepresentations: [WidgetRegionDisplayType: DisplayRepresentation] = [
        .states: DisplayRepresentation(title: "States", image: .init(systemName: "flag.fill")),
        .countries: DisplayRepresentation(title: "Countries", image: .init(systemName: "globe")),
        .continents: DisplayRepresentation(title: "Continents", image: .init(systemName: "globe.americas.fill"))
    ]

    var iconName: String {
        switch self {
        case .states: return "flag.fill"
        case .countries: return "globe"
        case .continents: return "globe.americas.fill"
        }
    }

    var color: Color {
        switch self {
        case .states: return .blue
        case .countries: return .green
        case .continents: return .orange
        }
    }
}

/// Intent for region statistics widget configuration
struct RegionStatsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configure Display"
    static var description: IntentDescription = "Choose which regions to display"

    @Parameter(title: "Regions to Show", default: [.states, .countries, .continents])
    var selectedRegions: [WidgetRegionDisplayType]

    init() {}

    init(selectedRegions: [WidgetRegionDisplayType]) {
        self.selectedRegions = selectedRegions
    }
}

/// Data model for region statistics
struct RegionStatsData {
    let stateCount: Int
    let totalStates: Int
    let countryCount: Int
    let totalCountries: Int
    let continentCount: Int
    let totalContinents: Int

    static let placeholder = RegionStatsData(
        stateCount: 0, totalStates: 50,
        countryCount: 0, totalCountries: 195,
        continentCount: 0, totalContinents: 7
    )
}

/// Timeline entry for region statistics widget
struct RegionStatsEntry: TimelineEntry {
    let date: Date
    let stats: RegionStatsData
    let configuration: RegionStatsWidgetIntent
}

/// Provider for region statistics widget
struct RegionStatsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RegionStatsEntry {
        RegionStatsEntry(
            date: Date(),
            stats: RegionStatsData.placeholder,
            configuration: RegionStatsWidgetIntent()
        )
    }

    func snapshot(for configuration: RegionStatsWidgetIntent, in context: Context) async -> RegionStatsEntry {
        RegionStatsEntry(
            date: Date(),
            stats: fetchRegionStats(),
            configuration: configuration
        )
    }

    func timeline(for configuration: RegionStatsWidgetIntent, in context: Context) async -> Timeline<RegionStatsEntry> {
        let stats = fetchRegionStats()
        let entry = RegionStatsEntry(date: Date(), stats: stats, configuration: configuration)
        let refreshDate = Calendar.current.date(byAdding: .hour, value: widgetRefreshIntervalHours, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(refreshDate))
    }

    /// Fetch region counts from Core Data
    private func fetchRegionStats() -> RegionStatsData {
        var result = RegionStatsData.placeholder

        let semaphore = DispatchSemaphore(value: 0)

        loadWidgetCoreData { context in
            defer { semaphore.signal() }

            guard let context = context else { return }

            // Fetch state records
            let stateRequest: NSFetchRequest<NSManagedObject> = NSFetchRequest(entityName: "RecordHistoryEntry")
            stateRequest.predicate = NSPredicate(format: "recordType == %@", "New State")

            // Fetch country records
            let countryRequest: NSFetchRequest<NSManagedObject> = NSFetchRequest(entityName: "RecordHistoryEntry")
            countryRequest.predicate = NSPredicate(format: "recordType == %@", "New Country")

            // Fetch continent records
            let continentRequest: NSFetchRequest<NSManagedObject> = NSFetchRequest(entityName: "RecordHistoryEntry")
            continentRequest.predicate = NSPredicate(format: "recordType == %@", "New Continent")

            do {
                let states = try context.fetch(stateRequest)
                let countries = try context.fetch(countryRequest)
                let continents = try context.fetch(continentRequest)

                // Count states (exclude DC and territories)
                let stateCount = states.filter { entry in
                    guard let code = entry.value(forKey: "regionCode") as? String else { return false }
                    // Exclude DC and US territories from count
                    let excludedCodes: Set<String> = ["DC", "US-DC", "PR", "US-PR", "VI", "US-VI", "GU", "US-GU", "AS", "US-AS", "MP", "US-MP"]
                    return !excludedCodes.contains(code)
                }.count

                // Count countries (exclude territories)
                let countryCount = countries.filter { entry in
                    guard let code = entry.value(forKey: "regionCode") as? String else { return true }
                    // Territory codes that don't count as sovereign countries
                    let territoryCodes: Set<String> = [
                        "GF", "MQ", "GP", "RE", "YT", "NC", "PF",  // French
                        "PT-20", "PT-30",  // Portuguese
                        "ES-CN",  // Spanish
                        "CW", "AW", "SX",  // Dutch
                        "BM", "VG", "KY", "FK", "SC", "GI",  // British
                        "FO", "GL",  // Danish
                        "CX", "CC", "NF",  // Australian
                        "CK", "NU", "TK"  // New Zealand
                    ]
                    return !territoryCodes.contains(code)
                }.count

                let continentCount = continents.count

                result = RegionStatsData(
                    stateCount: stateCount, totalStates: 50,
                    countryCount: countryCount, totalCountries: 195,
                    continentCount: continentCount, totalContinents: 7
                )
            } catch {
                print("RegionStatsWidget: Failed to fetch region stats: \(error)")
            }
        }

        semaphore.wait()
        return result
    }
}

/// View for region statistics widget
struct RegionStatsWidgetView: View {
    var entry: RegionStatsEntry
    @Environment(\.widgetFamily) var family

    /// Get the selected regions, ensuring at least one is selected
    private var selectedRegions: [WidgetRegionDisplayType] {
        let selected = entry.configuration.selectedRegions
        return selected.isEmpty ? [.states, .countries, .continents] : selected
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallWidgetView
            case .systemMedium:
                mediumWidgetView
            default:
                mediumWidgetView
            }
        }
        .widgetURL(deepLinkURL)
    }

    private var deepLinkURL: URL? {
        // Navigate to the first selected region type
        let section = selectedRegions.first?.rawValue.lowercased() ?? "states"
        return URL(string: "georecords://regions?section=\(section)")
    }

    // MARK: - Small Widget (adapts to selection count)
    private var smallWidgetView: some View {
        VStack(spacing: 4) {
            // Header
            HStack {
                Spacer()
                Text("Regions")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )
            }

            // Adapt layout based on selection count
            if selectedRegions.count == 1 {
                // Single large display
                singleStatView(for: selectedRegions[0])
            } else if selectedRegions.count == 2 {
                // Two items side by side
                HStack(spacing: 8) {
                    ForEach(selectedRegions, id: \.self) { region in
                        SmallRegionStatCell(
                            icon: region.iconName,
                            iconColor: region.color,
                            count: countFor(region),
                            total: totalFor(region)
                        )
                    }
                }
            } else {
                // Three items in a grid (2 on top, 1 centered below)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if selectedRegions.contains(.states) {
                            SmallRegionStatCell(
                                icon: WidgetRegionDisplayType.states.iconName,
                                iconColor: WidgetRegionDisplayType.states.color,
                                count: entry.stats.stateCount,
                                total: entry.stats.totalStates
                            )
                        }
                        if selectedRegions.contains(.countries) {
                            SmallRegionStatCell(
                                icon: WidgetRegionDisplayType.countries.iconName,
                                iconColor: WidgetRegionDisplayType.countries.color,
                                count: entry.stats.countryCount,
                                total: entry.stats.totalCountries
                            )
                        }
                    }
                    if selectedRegions.contains(.continents) {
                        SmallRegionStatCell(
                            icon: WidgetRegionDisplayType.continents.iconName,
                            iconColor: WidgetRegionDisplayType.continents.color,
                            count: entry.stats.continentCount,
                            total: entry.stats.totalContinents
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(2)
    }

    /// Single stat view for when only one region type is selected
    private func singleStatView(for region: WidgetRegionDisplayType) -> some View {
        VStack(spacing: 8) {
            Image(systemName: region.iconName)
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(region.color)

            Text("\(countFor(region))")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(region.color)

            Text("of \(totalFor(region))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text(region.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func countFor(_ region: WidgetRegionDisplayType) -> Int {
        switch region {
        case .states: return entry.stats.stateCount
        case .countries: return entry.stats.countryCount
        case .continents: return entry.stats.continentCount
        }
    }

    private func totalFor(_ region: WidgetRegionDisplayType) -> Int {
        switch region {
        case .states: return entry.stats.totalStates
        case .countries: return entry.stats.totalCountries
        case .continents: return entry.stats.totalContinents
        }
    }

    // MARK: - Medium Widget (3 columns like records widget)
    private var mediumWidgetView: some View {
        VStack(spacing: 4) {
            // Header
            HStack {
                Spacer()
                Text("Regions Visited")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            // 3 column layout
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 4) {
                MediumRegionStatCell(
                    icon: "flag.fill",
                    iconColor: .blue,
                    count: entry.stats.stateCount,
                    total: entry.stats.totalStates,
                    label: "States"
                )
                MediumRegionStatCell(
                    icon: "globe",
                    iconColor: .green,
                    count: entry.stats.countryCount,
                    total: entry.stats.totalCountries,
                    label: "Countries"
                )
                MediumRegionStatCell(
                    icon: "globe.americas.fill",
                    iconColor: .orange,
                    count: entry.stats.continentCount,
                    total: entry.stats.totalContinents,
                    label: "Continents"
                )
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
    }
}

/// Small widget cell for region stats (matches SmallRecordGridCell style)
struct SmallRegionStatCell: View {
    let icon: String
    let iconColor: Color
    let count: Int
    let total: Int?
    var label: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(iconColor)

            if let total = total {
                Text("\(count)/\(total)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(iconColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(iconColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            if let label = label {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Medium widget cell for region stats (matches RecordGridCell style)
struct MediumRegionStatCell: View {
    let icon: String
    let iconColor: Color
    let count: Int
    let total: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(iconColor)

            Text("\(count)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(iconColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            VStack(spacing: 0) {
                Text("of \(total)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Region Statistics Widget definition
struct RegionStatsWidget: Widget {
    let kind: String = "RegionStatsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RegionStatsWidgetIntent.self, provider: RegionStatsProvider()) { entry in
            if #available(iOS 17.0, *) {
                RegionStatsWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                RegionStatsWidgetView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Region Statistics")
        .description("See how many states, countries, and continents you've visited.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Region Map Widget (Large)

/// Map display type for map widget configuration
enum WidgetMapType: String, CaseIterable, Codable, AppEnum {
    case states = "States"
    case countries = "Countries"
    case continents = "Continents"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Map Type"

    static var caseDisplayRepresentations: [WidgetMapType: DisplayRepresentation] = [
        .states: DisplayRepresentation(title: "States", image: .init(systemName: "flag.fill")),
        .countries: DisplayRepresentation(title: "Countries", image: .init(systemName: "globe")),
        .continents: DisplayRepresentation(title: "Continents", image: .init(systemName: "globe.americas.fill"))
    ]

    /// Filename for the cached map image
    var cacheFilename: String {
        switch self {
        case .states: return "widget_map_states.png"
        case .countries: return "widget_map_countries.png"
        case .continents: return "widget_map_continents.png"
        }
    }
}

/// Intent for region map widget configuration
struct RegionMapWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configure Map"
    static var description: IntentDescription = "Choose which map to display"

    @Parameter(title: "Map Type", default: .states)
    var mapType: WidgetMapType

    init() {}

    init(mapType: WidgetMapType) {
        self.mapType = mapType
    }
}

/// Data model for region map
struct RegionMapData {
    let mapImage: Data?
    let regionCount: Int
    let totalRegions: Int
    let mapType: WidgetMapType

    static func placeholder(for mapType: WidgetMapType) -> RegionMapData {
        let (count, total) = switch mapType {
        case .states: (0, 50)
        case .countries: (0, 195)
        case .continents: (0, 7)
        }
        return RegionMapData(mapImage: nil, regionCount: count, totalRegions: total, mapType: mapType)
    }
}

/// Timeline entry for region map widget
struct RegionMapEntry: TimelineEntry {
    let date: Date
    let mapData: RegionMapData
    let configuration: RegionMapWidgetIntent
}

/// Provider for region map widget
struct RegionMapProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RegionMapEntry {
        RegionMapEntry(
            date: Date(),
            mapData: RegionMapData.placeholder(for: .states),
            configuration: RegionMapWidgetIntent()
        )
    }

    func snapshot(for configuration: RegionMapWidgetIntent, in context: Context) async -> RegionMapEntry {
        RegionMapEntry(
            date: Date(),
            mapData: fetchMapData(for: configuration.mapType),
            configuration: configuration
        )
    }

    func timeline(for configuration: RegionMapWidgetIntent, in context: Context) async -> Timeline<RegionMapEntry> {
        let mapData = fetchMapData(for: configuration.mapType)
        let entry = RegionMapEntry(date: Date(), mapData: mapData, configuration: configuration)
        let refreshDate = Calendar.current.date(byAdding: .hour, value: widgetRefreshIntervalHours, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(refreshDate))
    }

    /// Fetch map image and region count from shared storage
    private func fetchMapData(for mapType: WidgetMapType) -> RegionMapData {
        // Try to load cached map image from App Group
        var mapImageData: Data?
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            let cacheURL = appGroupURL.appendingPathComponent(mapType.cacheFilename)
            mapImageData = try? Data(contentsOf: cacheURL)
        }

        // Fetch region count from Core Data
        var regionCount = 0
        let semaphore = DispatchSemaphore(value: 0)

        loadWidgetCoreData { context in
            defer { semaphore.signal() }

            guard let context = context else { return }

            let recordType: String
            switch mapType {
            case .states: recordType = "New State"
            case .countries: recordType = "New Country"
            case .continents: recordType = "New Continent"
            }

            let request: NSFetchRequest<NSManagedObject> = NSFetchRequest(entityName: "RecordHistoryEntry")
            request.predicate = NSPredicate(format: "recordType == %@", recordType)

            do {
                let results = try context.fetch(request)

                switch mapType {
                case .states:
                    // Exclude DC and territories
                    let excludedCodes: Set<String> = ["DC", "US-DC", "PR", "US-PR", "VI", "US-VI", "GU", "US-GU", "AS", "US-AS", "MP", "US-MP"]
                    regionCount = results.filter { entry in
                        guard let code = entry.value(forKey: "regionCode") as? String else { return false }
                        return !excludedCodes.contains(code)
                    }.count

                case .countries:
                    // Exclude territories
                    let territoryCodes: Set<String> = [
                        "GF", "MQ", "GP", "RE", "YT", "NC", "PF",
                        "PT-20", "PT-30", "ES-CN",
                        "CW", "AW", "SX",
                        "BM", "VG", "KY", "FK", "SC", "GI",
                        "FO", "GL",
                        "CX", "CC", "NF",
                        "CK", "NU", "TK"
                    ]
                    regionCount = results.filter { entry in
                        guard let code = entry.value(forKey: "regionCode") as? String else { return true }
                        return !territoryCodes.contains(code)
                    }.count

                case .continents:
                    regionCount = results.count
                }
            } catch {
                print("Widget: Failed to fetch region count: \(error)")
            }
        }

        semaphore.wait()

        let totalRegions = switch mapType {
        case .states: 50
        case .countries: 195
        case .continents: 7
        }

        return RegionMapData(
            mapImage: mapImageData,
            regionCount: regionCount,
            totalRegions: totalRegions,
            mapType: mapType
        )
    }
}

/// View for region map widget (large size)
struct RegionMapWidgetView: View {
    var entry: RegionMapEntry

    var body: some View {
        VStack(spacing: 8) {
            // Header row with stats
            HStack {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(entry.mapData.regionCount)/\(entry.mapData.totalRegions)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Map or placeholder
            if let imageData = entry.mapData.mapImage,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .cornerRadius(10)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            } else {
                // Placeholder when no map is cached
                VStack(spacing: 12) {
                    Image(systemName: "map")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)

                    Text("Open app to generate map")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .widgetURL(deepLinkURL)
    }

    private var deepLinkURL: URL? {
        let section: String
        switch entry.configuration.mapType {
        case .states: section = "states"
        case .countries: section = "countries"
        case .continents: section = "continents"
        }
        return URL(string: "georecords://regions?section=\(section)")
    }

    private var iconName: String {
        switch entry.configuration.mapType {
        case .states: return "flag.fill"
        case .countries: return "globe"
        case .continents: return "globe.americas.fill"
        }
    }

    private var iconColor: Color {
        switch entry.configuration.mapType {
        case .states: return .blue
        case .countries: return .green
        case .continents: return .orange
        }
    }

    private var title: String {
        switch entry.configuration.mapType {
        case .states: return "States"
        case .countries: return "Countries"
        case .continents: return "Continents"
        }
    }
}

/// Region Map Widget definition
struct RegionMapWidget: Widget {
    let kind: String = "RegionMapWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RegionMapWidgetIntent.self, provider: RegionMapProvider()) { entry in
            if #available(iOS 17.0, *) {
                RegionMapWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                RegionMapWidgetView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Region Map")
        .description("View your visited regions on a map.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    GeoRecordsWidget()
} timeline: {
    RecordsEntry(
        date: .now,
        records: [
            WidgetRecordData(type: "Furthest North", value: "45.5231°", location: "Portland, OR", timestamp: .now),
            WidgetRecordData(type: "Furthest South", value: "25.7617°", location: "Miami, FL", timestamp: .now),
            WidgetRecordData(type: "Furthest East", value: "122.6765°", location: "Seattle, WA", timestamp: .now),
            WidgetRecordData(type: "Furthest West", value: "158.0001°", location: "Honolulu, HI", timestamp: .now)
        ],
        configuration: GeoRecordsWidgetIntent()
    )
}

#Preview("Medium", as: .systemMedium) {
    GeoRecordsWidget()
} timeline: {
    RecordsEntry(
        date: .now,
        records: [
            WidgetRecordData(type: "Furthest North", value: "45.5231°", location: "Portland, OR", timestamp: .now),
            WidgetRecordData(type: "Furthest South", value: "25.7617°", location: "Miami, FL", timestamp: .now),
            WidgetRecordData(type: "Furthest East", value: "122.6765°", location: "Seattle, WA", timestamp: .now),
            WidgetRecordData(type: "Furthest West", value: "158.0001°", location: "Honolulu, HI", timestamp: .now),
            WidgetRecordData(type: "Furthest Up", value: "14,505 ft", location: "Mt. Whitney, CA", timestamp: .now)
        ],
        configuration: GeoRecordsWidgetIntent()
    )
}

#Preview("Single Record", as: .systemSmall) {
    SingleRecordWidget()
} timeline: {
    SingleRecordEntry(
        date: .now,
        record: SingleRecordData(
            type: "Furthest Up",
            value: "14,505 ft",
            location: "Mt. Whitney, California",
            timestamp: .now,
            thumbnailImage: nil
        ),
        configuration: SingleRecordWidgetIntent(selectedRecord: .up)
    )
}
