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

// MARK: - Standard Record Order

/// Canonical order for displaying records throughout the app
let standardRecordOrder = [
    "Furthest North",
    "Furthest South",
    "Furthest East",
    "Furthest West",
    "Furthest Up",
    "Furthest Down",
    "Furthest from Home"
]

// MARK: - App Intent Configuration

enum WidgetRecordType: String, CaseIterable, AppEnum {
    case north = "Furthest North"
    case south = "Furthest South"
    case east = "Furthest East"
    case west = "Furthest West"
    case up = "Furthest Up"
    case down = "Furthest Down"
    case fromHome = "Furthest from Home"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Record Type"

    static var caseDisplayRepresentations: [WidgetRecordType: DisplayRepresentation] = [
        .north: DisplayRepresentation(title: "North", image: .init(systemName: "arrow.up.circle.fill")),
        .south: DisplayRepresentation(title: "South", image: .init(systemName: "arrow.down.circle.fill")),
        .east: DisplayRepresentation(title: "East", image: .init(systemName: "arrow.right.circle.fill")),
        .west: DisplayRepresentation(title: "West", image: .init(systemName: "arrow.left.circle.fill")),
        .up: DisplayRepresentation(title: "Up (Altitude)", image: .init(systemName: "mountain.2.fill")),
        .down: DisplayRepresentation(title: "Down (Altitude)", image: .init(systemName: "water.waves")),
        .fromHome: DisplayRepresentation(title: "From Home", image: .init(systemName: "house.circle.fill"))
    ]

    /// Sort order index for consistent ordering
    var sortOrder: Int {
        switch self {
        case .north: return 0
        case .south: return 1
        case .east: return 2
        case .west: return 3
        case .up: return 4
        case .down: return 5
        case .fromHome: return 6
        }
    }
}

enum WidgetTimeFrame: String, CaseIterable, AppEnum {
    case allTime = "All Time"
    case year = "This Year"
    case month = "This Month"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Time Frame"

    static var caseDisplayRepresentations: [WidgetTimeFrame: DisplayRepresentation] = [
        .allTime: DisplayRepresentation(title: "All Time"),
        .year: DisplayRepresentation(title: "This Year"),
        .month: DisplayRepresentation(title: "This Month")
    ]
}

struct GeoRecordsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configure Widget"
    static var description: IntentDescription = "Choose which records to display"

    @Parameter(title: "Records to Show", default: [.north, .south, .east, .west, .up, .down, .fromHome])
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
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: currentDate)!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    // MARK: - Data Fetching

    private func fetchRecords(for configuration: GeoRecordsWidgetIntent) -> [WidgetRecordData] {
        let selectedTypes = Set(configuration.selectedRecords.map { $0.rawValue })
        let timeFrame = configuration.timeFrame
        // Access shared Core Data container
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.georecords.shared"
        ) else {
            return [WidgetRecordData.placeholder]
        }

        let storeURL = appGroupURL.appendingPathComponent("GeoRecordsModel.sqlite")

        // Create persistent container with same options as main app
        let container = NSPersistentContainer(name: "GeoRecordsModel")
        let storeDescription = NSPersistentStoreDescription(url: storeURL)

        // Must match main app's settings to avoid read-only mode
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        storeDescription.isReadOnly = true  // Widget only reads data

        container.persistentStoreDescriptions = [storeDescription]

        var records: [WidgetRecordData] = []
        let semaphore = DispatchSemaphore(value: 0)

        container.loadPersistentStores { _, error in
            defer { semaphore.signal() }

            if let error = error {
                print("Widget: Failed to load Core Data: \(error)")
                return
            }

            let context = container.viewContext
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "RecordHistoryEntry")
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

            do {
                guard let entries = try context.fetch(request) as? [NSManagedObject] else { return }

                // Get unit system from UserDefaults
                // Key "unitSystem" is defined in main app's Constants.swift as UserDefaultsKey.unitSystem
                // Values: "imperial" or "metric" (see UnitSystem enum in Constants.swift)
                let sharedDefaults = UserDefaults(suiteName: "group.com.georecords.shared")
                let unitSystemString = sharedDefaults?.string(forKey: "unitSystem") ?? "imperial"
                let unitSystem = unitSystemString == "metric" ? "metric" : "imperial"

                // Calculate time frame boundaries
                let calendar = Calendar.current
                let now = Date()
                let timeFrameStart: Date
                switch timeFrame {
                case .allTime:
                    timeFrameStart = Date.distantPast
                case .year:
                    timeFrameStart = calendar.dateInterval(of: .year, for: now)?.start ?? now
                case .month:
                    timeFrameStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
                }

                // Filter entries by time frame
                let filteredEntries = entries.filter { entry in
                    guard let timestamp = entry.value(forKey: "timestamp") as? Date else { return false }
                    return timestamp >= timeFrameStart
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
                        switch type {
                        case "Furthest North", "Furthest East", "Furthest Up", "Furthest from Home":
                            shouldReplace = newValue > existingValue
                        case "Furthest South", "Furthest West", "Furthest Down":
                            shouldReplace = newValue < existingValue
                        default:
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
                    let formattedValue = formatValue(value: value, recordType: type, unitSystem: unitSystem)

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

    private func formatValue(value: Double, recordType: String, unitSystem: String) -> String {
        switch recordType {
        case "Furthest North", "Furthest South", "Furthest East", "Furthest West":
            return String(format: "%.4f°", value)

        case "Furthest Up", "Furthest Down":
            if unitSystem == "imperial" {
                let feet = value * 3.28084
                return String(format: "%.0f ft", feet)
            } else {
                return String(format: "%.0f m", value)
            }

        case "Furthest from Home":
            if unitSystem == "imperial" {
                let miles = value / 1609.344
                return String(format: "%.2f mi", miles)
            } else {
                let km = value / 1000.0
                return String(format: "%.2f km", km)
            }

        default:
            return "\(value)"
        }
    }
}

// MARK: - Widget View

struct GeoRecordsWidgetEntryView : View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Compact header
            HStack(spacing: 4) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 10))
                Text("GeoRecords")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.secondary)
            .padding(.bottom, 2)

            // Records - show more based on widget size
            let recordsToShow = family == .systemMedium ? min(6, entry.records.count) : min(4, entry.records.count)

            if family == .systemMedium {
                // Two columns for medium widget
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<(recordsToShow + 1) / 2, id: \.self) { index in
                            if index < entry.records.count {
                                CompactRecordRowView(record: entry.records[index])
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach((recordsToShow + 1) / 2..<recordsToShow, id: \.self) { index in
                            if index < entry.records.count {
                                CompactRecordRowView(record: entry.records[index])
                            }
                        }
                    }
                }
            } else {
                // Single column for small widget
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<recordsToShow, id: \.self) { index in
                        if index < entry.records.count {
                            CompactRecordRowView(record: entry.records[index])
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

struct CompactRecordRowView: View {
    let record: WidgetRecordData

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: iconForType(record.type))
                    .font(.system(size: 11))
                    .foregroundColor(colorForType(record.type))
                    .frame(width: 14)

                Text(shortName(for: record.type))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(record.value)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Text(record.location)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .padding(.leading, 18)
        }
    }

    private func shortName(for type: String) -> String {
        switch type {
        case "Furthest North": return "North"
        case "Furthest South": return "South"
        case "Furthest East": return "East"
        case "Furthest West": return "West"
        case "Furthest Up": return "Up"
        case "Furthest Down": return "Down"
        case "Furthest from Home": return "From Home"
        default: return type
        }
    }

    private func iconForType(_ type: String) -> String {
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

    private func colorForType(_ type: String) -> Color {
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
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: currentDate)!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func fetchRecord(for configuration: SingleRecordWidgetIntent) -> SingleRecordData {
        let recordType = configuration.selectedRecord.rawValue
        let timeFrame = configuration.timeFrame

        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.georecords.shared"
        ) else {
            return SingleRecordData.placeholder
        }

        let storeURL = appGroupURL.appendingPathComponent("GeoRecordsModel.sqlite")

        // Create persistent container with same options as main app
        let container = NSPersistentContainer(name: "GeoRecordsModel")
        let storeDescription = NSPersistentStoreDescription(url: storeURL)

        // Must match main app's settings to avoid read-only mode
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        storeDescription.isReadOnly = true  // Widget only reads data

        container.persistentStoreDescriptions = [storeDescription]

        var result: SingleRecordData = SingleRecordData.placeholder
        let semaphore = DispatchSemaphore(value: 0)

        container.loadPersistentStores { _, error in
            defer { semaphore.signal() }

            if let error = error {
                print("Widget: Failed to load Core Data: \(error)")
                return
            }

            let context = container.viewContext
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "RecordHistoryEntry")
            request.predicate = NSPredicate(format: "recordType == %@", recordType)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

            do {
                guard let entries = try context.fetch(request) as? [NSManagedObject] else { return }

                // Get unit system from shared UserDefaults
                // Key "unitSystem" is defined in main app's Constants.swift as UserDefaultsKey.unitSystem
                // Values: "imperial" or "metric" (see UnitSystem enum in Constants.swift)
                let sharedDefaults = UserDefaults(suiteName: "group.com.georecords.shared")
                let unitSystemString = sharedDefaults?.string(forKey: "unitSystem") ?? "imperial"
                let unitSystem = unitSystemString == "metric" ? "metric" : "imperial"

                // Calculate time frame boundaries
                let calendar = Calendar.current
                let now = Date()
                let timeFrameStart: Date
                switch timeFrame {
                case .allTime:
                    timeFrameStart = Date.distantPast
                case .year:
                    timeFrameStart = calendar.dateInterval(of: .year, for: now)?.start ?? now
                case .month:
                    timeFrameStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
                }

                // Filter by time frame and find most extreme
                let filteredEntries = entries.filter { entry in
                    guard let timestamp = entry.value(forKey: "timestamp") as? Date else { return false }
                    return timestamp >= timeFrameStart
                }

                var bestEntry: NSManagedObject?
                for entry in filteredEntries {
                    guard let newValue = entry.value(forKey: "value") as? Double else { continue }

                    if let existing = bestEntry,
                       let existingValue = existing.value(forKey: "value") as? Double {
                        let shouldReplace: Bool
                        switch recordType {
                        case "Furthest North", "Furthest East", "Furthest Up", "Furthest from Home":
                            shouldReplace = newValue > existingValue
                        case "Furthest South", "Furthest West", "Furthest Down":
                            shouldReplace = newValue < existingValue
                        default:
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
                    let formattedValue = formatValue(value: value, recordType: recordType, unitSystem: unitSystem)

                    // Create thumbnail using ImageIO to avoid loading full image into memory
                    var thumbnail: UIImage?
                    if let photoData = entry.value(forKey: "photoData") as? Data {
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

    private func formatValue(value: Double, recordType: String, unitSystem: String) -> String {
        switch recordType {
        case "Furthest North", "Furthest South", "Furthest East", "Furthest West":
            return String(format: "%.4f°", value)
        case "Furthest Up", "Furthest Down":
            if unitSystem == "imperial" {
                return String(format: "%.0f ft", value * 3.28084)
            } else {
                return String(format: "%.0f m", value)
            }
        case "Furthest from Home":
            if unitSystem == "imperial" {
                return String(format: "%.2f mi", value / 1609.344)
            } else {
                return String(format: "%.2f km", value / 1000.0)
            }
        default:
            return "\(value)"
        }
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
}

/// View for single record widget
struct SingleRecordWidgetView: View {
    var entry: SingleRecordEntry

    private var hasPhoto: Bool {
        entry.record.thumbnailImage != nil
    }

    var body: some View {
        let record = entry.record

        GeometryReader { geometry in
            ZStack {
                // Background photo if available (already resized in provider)
                if let thumbnail = record.thumbnailImage {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()

                    // Gradient overlay for readability
                    LinearGradient(
                        colors: [.black.opacity(0.6), .black.opacity(0.3), .black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    // Header with icon and type
                    HStack(spacing: 6) {
                        Image(systemName: iconForType(record.type))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(hasPhoto ? .white : colorForType(record.type))

                        Text(shortName(for: record.type))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(hasPhoto ? .white : .primary)

                        Spacer()
                    }

                    Spacer()

                    // Value
                    Text(record.value)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(hasPhoto ? .white : colorForType(record.type))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)

                    // Location
                    Text(record.location)
                        .font(.system(size: 11))
                        .foregroundColor(hasPhoto ? .white.opacity(0.9) : .secondary)
                        .lineLimit(2)
                }
                .padding(12)
            }
        }
    }

    private func shortName(for type: String) -> String {
        switch type {
        case "Furthest North": return "North"
        case "Furthest South": return "South"
        case "Furthest East": return "East"
        case "Furthest West": return "West"
        case "Furthest Up": return "Up"
        case "Furthest Down": return "Down"
        case "Furthest from Home": return "From Home"
        default: return type
        }
    }

    private func iconForType(_ type: String) -> String {
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

    private func colorForType(_ type: String) -> Color {
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
}

/// Single record widget configuration
struct SingleRecordWidget: Widget {
    let kind: String = "SingleRecordWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SingleRecordWidgetIntent.self, provider: SingleRecordProvider()) { entry in
            if #available(iOS 17.0, *) {
                SingleRecordWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                SingleRecordWidgetView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Single Record")
        .description("Display one record with its photo.")
        .supportedFamilies([.systemSmall])
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
            WidgetRecordData(type: "Furthest Up", value: "14,505 ft", location: "Mt. Whitney, CA", timestamp: .now),
            WidgetRecordData(type: "Furthest Down", value: "282 ft", location: "Death Valley, CA", timestamp: .now)
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
