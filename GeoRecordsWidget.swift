import WidgetKit
import SwiftUI
import CoreData
import CoreLocation
import os.log

// Widget uses shared models for TimeFrame enum

// Custom logger for widget
private let widgetLogger = Logger(subsystem: "com.davidlaporte.GeoRecords", category: "Widget")

// MARK: - Widget Timeline Entry
struct RecordEntry: TimelineEntry {
    let date: Date
    let records: [SimpleRecord]
    let stats: WidgetStats
}

// Simplified record for widget display
struct SimpleRecord: Identifiable {
    let id = UUID()
    let type: String
    let value: String
    let emoji: String
    let color: Color
}

// Widget statistics
struct WidgetStats {
    let totalRecords: Int
    let recordsThisMonth: Int
    let recordsThisYear: Int
    let daysSinceLastRecord: Int
}

// MARK: - Widget Timeline Provider
struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry {
        widgetLogger.info("🎨 Widget: placeholder() called")
        return RecordEntry(date: Date(), records: placeholderRecords(), stats: placeholderStats())
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
        widgetLogger.info("📸 Widget: getSnapshot called")
        let records = fetchRecords()
        let stats = fetchStats()
        let entry = RecordEntry(date: Date(), records: records, stats: stats)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        widgetLogger.info("⏰ Widget: getTimeline called")
        let currentDate = Date()
        let records = fetchRecords()
        let stats = fetchStats()
        let entry = RecordEntry(date: currentDate, records: records, stats: stats)

        // Update every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
    }

    // MARK: - Core Data Helper

    /// Shared container instance to avoid recreating it
    private static var sharedContainer: NSPersistentCloudKitContainer?

    /// Creates Core Data container configured for App Group access
    private func createContainer() -> NSManagedObjectContext {
        // Reuse existing container if available
        if let existing = Self.sharedContainer {
            return existing.viewContext
        }

        let container = NSPersistentCloudKitContainer(name: "GeoRecordsModel")

        // Configure for App Groups so widget can access main app's data
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.georecords.shared") {
            let storeURL = appGroupURL.appendingPathComponent("GeoRecordsModel.sqlite")
            let storeDescription = NSPersistentStoreDescription(url: storeURL)
            storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            container.persistentStoreDescriptions = [storeDescription]

            widgetLogger.info("📦 Widget: Configured App Group at \(storeURL.path)")
        } else {
            widgetLogger.error("❌ Widget: Failed to access App Group!")
        }

        // Load stores synchronously
        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        container.loadPersistentStores { description, error in
            if let error = error {
                widgetLogger.error("❌ Widget: Failed to load store: \(error.localizedDescription)")
                loadError = error
            } else {
                widgetLogger.info("✅ Widget: Loaded store from \(description.url?.path ?? "unknown")")
            }
            semaphore.signal()
        }

        semaphore.wait()

        // Cache the container
        Self.sharedContainer = container

        return container.viewContext
    }

    // MARK: - Fetch Records from Core Data
    private func fetchRecords() -> [SimpleRecord] {
        widgetLogger.info("🔍 Widget: Starting to fetch records...")
        let context = createContainer()
        let recordTypes = [
            "Furthest North",
            "Furthest South",
            "Furthest East",
            "Furthest West",
            "Furthest Up",
            "Furthest Down",
            "Furthest from Home"
        ]

        var records: [SimpleRecord] = []

        for type in recordTypes {
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "recordType == %@ AND timeFrame == %@", type, "All Time")
            request.fetchLimit = 1

            // Sort appropriately for each type
            switch type {
            case "Furthest North", "Furthest East", "Furthest Up", "Furthest from Home":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: false)]
            case "Furthest South", "Furthest West", "Furthest Down":
                request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: true)]
            default:
                request.sortDescriptors = []
            }

            do {
                let results = try context.fetch(request)
                if let entry = results.first {
                    let formattedValue = formatValue(entry.value, for: type)
                    let (emoji, color) = styleForRecordType(type)
                    records.append(SimpleRecord(type: type, value: formattedValue, emoji: emoji, color: color))
                    widgetLogger.info("✅ Widget: Found \(type) = \(formattedValue)")
                } else {
                    widgetLogger.warning("⚠️ Widget: No record found for \(type)")
                }
            } catch {
                widgetLogger.error("❌ Widget: Failed to fetch \(type): \(error.localizedDescription)")
            }
        }

        if records.isEmpty {
            widgetLogger.warning("⚠️ Widget: No records found, using placeholders")
            return placeholderRecords()
        } else {
            widgetLogger.info("✅ Widget: Successfully loaded \(records.count) records")
            return records
        }
    }

    // MARK: - Fetch Statistics
    private func fetchStats() -> WidgetStats {
        let context = createContainer()
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        do {
            let allEntries = try context.fetch(request)
            let totalRecords = allEntries.count

            // Get current month and year boundaries
            let calendar = Calendar.current
            let now = Date()
            let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
            let startOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now

            // Count records this month/year
            let recordsThisMonth = allEntries.filter { entry in
                guard let timestamp = entry.timestamp else { return false }
                return timestamp >= startOfMonth
            }.count

            let recordsThisYear = allEntries.filter { entry in
                guard let timestamp = entry.timestamp else { return false }
                return timestamp >= startOfYear
            }.count

            // Calculate days since last record
            let daysSinceLastRecord: Int
            if let lastRecordDate = allEntries.first?.timestamp {
                daysSinceLastRecord = calendar.dateComponents([.day], from: lastRecordDate, to: now).day ?? 0
            } else {
                daysSinceLastRecord = 0
            }

            return WidgetStats(
                totalRecords: totalRecords,
                recordsThisMonth: recordsThisMonth,
                recordsThisYear: recordsThisYear,
                daysSinceLastRecord: daysSinceLastRecord
            )
        } catch {
            widgetLogger.error("❌ Widget: Failed to fetch stats: \(error.localizedDescription)")
            return placeholderStats()
        }
    }

    private func formatValue(_ value: Double, for type: String) -> String {
        // Get unit system from App Group UserDefaults
        let defaults = UserDefaults(suiteName: "group.com.georecords.shared") ?? UserDefaults.standard
        let unitSystemRaw = defaults.string(forKey: "unitSystem") ?? "imperial"
        let isImperial = (unitSystemRaw == "imperial")

        if type.contains("North") || type.contains("South") ||
           type.contains("East") || type.contains("West") {
            return String(format: "%.2f°", value)
        } else if type.contains("Up") || type.contains("Down") {
            // Altitude stored in meters
            if isImperial {
                let feet = value * 3.28084
                return "\(Int(round(feet))) ft"
            } else {
                return "\(Int(round(value))) m"
            }
        } else if type == "Furthest from Home" {
            // Distance stored in METERS (not feet!)
            if isImperial {
                let miles = value / 1609.344  // meters to miles
                return String(format: "%.1f mi", miles)
            } else {
                if value >= 1000 {
                    let km = value / 1000.0
                    return String(format: "%.1f km", km)
                } else {
                    return "\(Int(round(value))) m"
                }
            }
        }
        return String(format: "%.2f", value)
    }

    private func styleForRecordType(_ type: String) -> (emoji: String, color: Color) {
        switch type {
        case "Furthest North": return ("⬆️", .blue)
        case "Furthest South": return ("⬇️", .cyan)
        case "Furthest East": return ("➡️", .orange)
        case "Furthest West": return ("⬅️", .purple)
        case "Furthest Up": return ("🏔", .green)
        case "Furthest Down": return ("🏖", .brown)
        case "Furthest from Home": return ("🏠", .red)
        default: return ("📍", .gray)
        }
    }

    private func placeholderRecords() -> [SimpleRecord] {
        return [
            SimpleRecord(type: "Furthest North", value: "45.52°", emoji: "⬆️", color: .blue),
            SimpleRecord(type: "Furthest South", value: "35.23°", emoji: "⬇️", color: .cyan),
            SimpleRecord(type: "Furthest East", value: "-115.42°", emoji: "➡️", color: .orange),
            SimpleRecord(type: "Furthest West", value: "-122.68°", emoji: "⬅️", color: .purple),
            SimpleRecord(type: "Furthest Up", value: "5,280 ft", emoji: "🏔", color: .green),
            SimpleRecord(type: "Furthest Down", value: "0 ft", emoji: "🏖", color: .brown),
            SimpleRecord(type: "Furthest from Home", value: "125 mi", emoji: "🏠", color: .red)
        ]
    }

    private func placeholderStats() -> WidgetStats {
        return WidgetStats(
            totalRecords: 42,
            recordsThisMonth: 3,
            recordsThisYear: 18,
            daysSinceLastRecord: 5
        )
    }
}

// MARK: - Widget Views

// Small Widget - Compact 3-record display with stats
struct SmallWidgetView: View {
    let records: [SimpleRecord]
    let stats: WidgetStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Text("GeoRecords")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Spacer()
                if stats.daysSinceLastRecord == 0 {
                    Text("🎉")
                        .font(.caption)
                } else {
                    Text("\(stats.daysSinceLastRecord)d")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 4)

            // Records
            ForEach(records.prefix(3)) { record in
                HStack(spacing: 4) {
                    Text(record.emoji)
                        .font(.system(size: 16))
                    Text(shortName(for: record.type))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(record.value)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(record.color)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Footer stats
            HStack(spacing: 4) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(stats.recordsThisMonth) this month")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
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
}

// Medium Widget - All 7 records in grid layout
struct MediumWidgetView: View {
    let records: [SimpleRecord]
    let stats: WidgetStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Geographical Records")
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(stats.totalRecords) total")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if stats.daysSinceLastRecord > 0 {
                        Text("\(stats.daysSinceLastRecord) days ago")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("🎉 New today!")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }

            Divider()

            // Records grid
            VStack(spacing: 4) {
                ForEach(records) { record in
                    HStack(spacing: 6) {
                        Text(record.emoji)
                            .font(.system(size: 14))
                        Text(shortName(for: record.type))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Spacer()
                        Text(record.value)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(record.color)
                    }
                }
            }
        }
        .padding(14)
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
}

// Large Widget - Records + Stats Dashboard
struct LargeWidgetView: View {
    let records: [SimpleRecord]
    let stats: WidgetStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("Geographical Records")
                .font(.title3)
                .fontWeight(.bold)

            // Stats cards
            HStack(spacing: 12) {
                StatCard(value: "\(stats.totalRecords)", label: "Total", icon: "flag.fill", color: .blue)
                StatCard(value: "\(stats.recordsThisMonth)", label: "This Month", icon: "calendar", color: .green)
                StatCard(value: "\(stats.recordsThisYear)", label: "This Year", icon: "chart.bar.fill", color: .orange)
                if stats.daysSinceLastRecord == 0 {
                    StatCard(value: "🎉", label: "New Today", icon: "sparkles", color: .purple)
                } else {
                    StatCard(value: "\(stats.daysSinceLastRecord)", label: "Days Ago", icon: "clock.fill", color: .gray)
                }
            }

            Divider()

            // Records list
            VStack(spacing: 6) {
                ForEach(records) { record in
                    HStack(spacing: 8) {
                        Text(record.emoji)
                            .font(.system(size: 18))
                        Text(shortName(for: record.type))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(record.value)
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(record.color)
                    }
                    .padding(.vertical, 2)
                }
            }

            Spacer()
        }
        .padding(16)
    }

    private func shortName(for type: String) -> String {
        switch type {
        case "Furthest North": return "Furthest North"
        case "Furthest South": return "Furthest South"
        case "Furthest East": return "Furthest East"
        case "Furthest West": return "Furthest West"
        case "Furthest Up": return "Furthest Up"
        case "Furthest Down": return "Furthest Down"
        case "Furthest from Home": return "From Home"
        default: return type
        }
    }
}

// Stat Card component for large widget
struct StatCard: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.1))
        )
    }
}

// MARK: - Main Widget View
struct GeoRecordsWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: RecordEntry

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Content
            Group {
                switch family {
                case .systemSmall:
                    SmallWidgetView(records: entry.records, stats: entry.stats)
                case .systemMedium:
                    MediumWidgetView(records: entry.records, stats: entry.stats)
                case .systemLarge:
                    LargeWidgetView(records: entry.records, stats: entry.stats)
                default:
                    MediumWidgetView(records: entry.records, stats: entry.stats)
                }
            }
        }
        .widgetURL(URL(string: "georecords://records"))
    }
}

// MARK: - Lock Screen Widgets (iOS 16+)

// Accessory Circular - Shows days since last record or celebration
struct AccessoryCircularWidgetView: View {
    let stats: WidgetStats

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 2) {
                if stats.daysSinceLastRecord == 0 {
                    Image(systemName: "star.fill")
                        .font(.title3)
                    Text("New!")
                        .font(.caption2)
                } else {
                    Text("\(stats.daysSinceLastRecord)")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("days")
                        .font(.caption2)
                }
            }
        }
    }
}

// Accessory Rectangular - Shows mini stats
struct AccessoryRectangularWidgetView: View {
    let stats: WidgetStats
    let records: [SimpleRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                Text("GeoRecords")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            Text("\(stats.recordsThisMonth) this month • \(stats.totalRecords) total")
                .font(.caption2)
                .foregroundColor(.secondary)
            if let topRecord = records.first {
                Text("\(topRecord.emoji) \(topRecord.value)")
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
    }
}

// Accessory Inline - Simple text for lock screen
struct AccessoryInlineWidgetView: View {
    let stats: WidgetStats

    var body: some View {
        if stats.daysSinceLastRecord == 0 {
            Text("🎉 New record today!")
        } else if stats.daysSinceLastRecord == 1 {
            Text("📍 Last record: yesterday")
        } else {
            Text("📍 Last record: \(stats.daysSinceLastRecord)d ago")
        }
    }
}

// MARK: - Widget Configuration
struct GeoRecordsWidget: Widget {
    let kind: String = "GeoRecordsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordProvider()) { entry in
            if #available(iOS 16.0, *) {
                GeoRecordsWidgetEntryView(entry: entry)
                    .containerBackground(for: .widget) {
                        LinearGradient(
                            gradient: Gradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
            } else {
                GeoRecordsWidgetEntryView(entry: entry)
            }
        }
        .configurationDisplayName("GeoRecords")
        .description("View your current geographical records at a glance")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// Lock Screen Widget Configuration (iOS 16+)
@available(iOS 16.0, *)
struct GeoRecordsLockScreenWidget: Widget {
    let kind: String = "GeoRecordsLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordProvider()) { entry in
            switch entry.widgetFamily {
            case .accessoryCircular:
                AccessoryCircularWidgetView(stats: entry.stats)
            case .accessoryRectangular:
                AccessoryRectangularWidgetView(stats: entry.stats, records: entry.records)
            case .accessoryInline:
                AccessoryInlineWidgetView(stats: entry.stats)
            default:
                EmptyView()
            }
        }
        .configurationDisplayName("GeoRecords")
        .description("Quick stats on your lock screen")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Widget Bundle
@main
struct GeoRecordsWidgetBundle: WidgetBundle {
    var body: some Widget {
        GeoRecordsWidget()
        if #available(iOS 16.0, *) {
            GeoRecordsLockScreenWidget()
        }
    }
}

// MARK: - Preview
struct GeoRecordsWidget_Previews: PreviewProvider {
    static var previews: some View {
        let sampleRecords = [
            SimpleRecord(type: "Furthest North", value: "45.52°", emoji: "⬆️", color: .blue),
            SimpleRecord(type: "Furthest South", value: "35.23°", emoji: "⬇️", color: .cyan),
            SimpleRecord(type: "Furthest East", value: "-115.42°", emoji: "➡️", color: .orange),
            SimpleRecord(type: "Furthest West", value: "-122.68°", emoji: "⬅️", color: .purple),
            SimpleRecord(type: "Furthest Up", value: "5,280 ft", emoji: "🏔", color: .green),
            SimpleRecord(type: "Furthest Down", value: "0 ft", emoji: "🏖", color: .brown),
            SimpleRecord(type: "Furthest from Home", value: "125 mi", emoji: "🏠", color: .red)
        ]

        let sampleStats = WidgetStats(
            totalRecords: 42,
            recordsThisMonth: 3,
            recordsThisYear: 18,
            daysSinceLastRecord: 2
        )

        let entry = RecordEntry(date: Date(), records: sampleRecords, stats: sampleStats)

        // Home Screen Widgets
        Group {
            GeoRecordsWidgetEntryView(entry: entry)
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Small Widget")

            GeoRecordsWidgetEntryView(entry: entry)
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium Widget")

            GeoRecordsWidgetEntryView(entry: entry)
                .previewContext(WidgetPreviewContext(family: .systemLarge))
                .previewDisplayName("Large Widget")
        }

        // Lock Screen Widgets (iOS 16+)
        if #available(iOS 16.0, *) {
            Group {
                AccessoryCircularWidgetView(stats: sampleStats)
                    .previewContext(WidgetPreviewContext(family: .accessoryCircular))
                    .previewDisplayName("Lock Screen - Circular")

                AccessoryRectangularWidgetView(stats: sampleStats, records: sampleRecords)
                    .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                    .previewDisplayName("Lock Screen - Rectangular")

                AccessoryInlineWidgetView(stats: sampleStats)
                    .previewContext(WidgetPreviewContext(family: .accessoryInline))
                    .previewDisplayName("Lock Screen - Inline")
            }
        }
    }
}
