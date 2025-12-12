//
//  GeoRecordsWidget.swift
//  GeoRecordsWidget
//
//  Created by David LaPorte on 12/12/25.
//

import WidgetKit
import SwiftUI
import CoreData

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
}

// MARK: - Timeline Entry

struct RecordsEntry: TimelineEntry {
    let date: Date
    let records: [WidgetRecordData]
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> RecordsEntry {
        RecordsEntry(
            date: Date(),
            records: [WidgetRecordData.placeholder]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordsEntry) -> ()) {
        let entry = RecordsEntry(
            date: Date(),
            records: fetchRecords()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let currentDate = Date()
        let records = fetchRecords()

        // Create an entry for now
        let entry = RecordsEntry(date: currentDate, records: records)

        // Refresh every hour
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    // MARK: - Data Fetching

    private func fetchRecords() -> [WidgetRecordData] {
        // Access shared Core Data container
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.georecords.shared"
        ) else {
            return [WidgetRecordData.placeholder]
        }

        let storeURL = appGroupURL.appendingPathComponent("GeoRecordsModel.sqlite")

        // Create persistent container
        let container = NSPersistentContainer(name: "GeoRecordsModel")
        let storeDescription = NSPersistentStoreDescription(url: storeURL)
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
                let sharedDefaults = UserDefaults(suiteName: "group.com.georecords.shared")
                let unitSystemString = sharedDefaults?.string(forKey: "unitSystem") ?? "imperial"
                let unitSystem = unitSystemString == "metric" ? "metric" : "imperial"

                // Group by record type and get the latest (most extreme) for each
                var latestByType: [String: NSManagedObject] = [:]

                for entry in entries {
                    guard let type = entry.value(forKey: "recordType") as? String else { continue }

                    // For all-time records, keep the most extreme value
                    if let existing = latestByType[type],
                       let existingValue = existing.value(forKey: "value") as? Double,
                       let newValue = entry.value(forKey: "value") as? Double {

                        // Determine which is more extreme based on record type
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

                // Convert to widget data (show top 6 most recent for medium widget)
                let sortedEntries = latestByType.values.sorted {
                    let date1 = $0.value(forKey: "timestamp") as? Date ?? Date.distantPast
                    let date2 = $1.value(forKey: "timestamp") as? Date ?? Date.distantPast
                    return date1 > date2
                }

                records = sortedEntries.prefix(7).compactMap { entry in
                    guard let type = entry.value(forKey: "recordType") as? String,
                          let value = entry.value(forKey: "value") as? Double,
                          let timestamp = entry.value(forKey: "timestamp") as? Date else {
                        return nil
                    }

                    let location = entry.value(forKey: "locationName") as? String ?? "Unknown"

                    // Format value based on record type
                    let formattedValue = formatValue(value: value, recordType: type, unitSystem: unitSystem)

                    return WidgetRecordData(
                        type: type,
                        value: formattedValue,
                        location: location,
                        timestamp: timestamp
                    )
                }

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
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                GeoRecordsWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                GeoRecordsWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("GeoRecords")
        .description("View your geographical records at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
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
        ]
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
        ]
    )
}
