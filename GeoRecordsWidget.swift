import WidgetKit
import SwiftUI
import CoreData

// MARK: - Widget Timeline Entry
struct RecordEntry: TimelineEntry {
    let date: Date
    let records: [SimpleRecord]
}

// Simplified record for widget display
struct SimpleRecord {
    let type: String
    let value: String
}

// MARK: - Widget Timeline Provider
struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry {
        RecordEntry(date: Date(), records: placeholderRecords())
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
        let entry = RecordEntry(date: Date(), records: fetchRecords())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        let currentDate = Date()
        let records = fetchRecords()
        let entry = RecordEntry(date: currentDate, records: records)

        // Update every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
    }

    // MARK: - Fetch Records from Core Data
    private func fetchRecords() -> [SimpleRecord] {
        let context = PersistenceController.shared.container.viewContext
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
            request.predicate = NSPredicate(format: "recordType == %@", type)
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
                    records.append(SimpleRecord(type: type, value: formattedValue))
                }
            } catch {
                print("Widget failed to fetch \(type): \(error)")
            }
        }

        return records.isEmpty ? placeholderRecords() : records
    }

    private func formatValue(_ value: Double, for type: String) -> String {
        // Get unit system from UserDefaults
        let unitSystemRaw = UserDefaults.standard.string(forKey: "unitSystem") ?? "imperial"
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
            // Distance stored in feet
            if isImperial {
                let miles = value / 5280.0
                return String(format: "%.2f mi", miles)
            } else {
                let meters = value * 0.3048
                if meters >= 1000 {
                    let km = meters / 1000.0
                    return String(format: "%.2f km", km)
                } else {
                    return "\(Int(round(meters))) m"
                }
            }
        }
        return String(format: "%.2f", value)
    }

    private func placeholderRecords() -> [SimpleRecord] {
        return [
            SimpleRecord(type: "Furthest North", value: "45.52°"),
            SimpleRecord(type: "Furthest South", value: "35.23°"),
            SimpleRecord(type: "Furthest East", value: "-115.42°")
        ]
    }
}

// MARK: - Widget Views

struct SmallWidgetView: View {
    let records: [SimpleRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Records")
                .font(.headline)
                .foregroundColor(.primary)

            ForEach(records.prefix(3), id: \.type) { record in
                HStack {
                    Text(shortName(for: record.type))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(record.value)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
    }

    private func shortName(for type: String) -> String {
        let shortName = FormatUtils.shortName(for: type)
        // Add emoji prefix for widget
        switch type {
        case "Furthest North": return "⬆️ \(shortName)"
        case "Furthest South": return "⬇️ \(shortName)"
        case "Furthest East": return "➡️ \(shortName)"
        case "Furthest West": return "⬅️ \(shortName)"
        case "Furthest Up": return "🏔 \(shortName)"
        case "Furthest Down": return "🏖 \(shortName)"
        case "Furthest from Home": return "🏠 \(shortName)"
        default: return type
        }
    }
}

struct MediumWidgetView: View {
    let records: [SimpleRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Geographical Records")
                .font(.headline)
                .foregroundColor(.primary)

            ForEach(records, id: \.type) { record in
                HStack {
                    Text(shortName(for: record.type))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(record.value)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
    }

    private func shortName(for type: String) -> String {
        let shortName = FormatUtils.shortName(for: type)
        switch type {
        case "Furthest North": return "⬆️ \(shortName)"
        case "Furthest South": return "⬇️ \(shortName)"
        case "Furthest East": return "➡️ \(shortName)"
        case "Furthest West": return "⬅️ \(shortName)"
        case "Furthest Up": return "🏔 \(shortName)"
        case "Furthest Down": return "🏖 \(shortName)"
        case "Furthest from Home": return "🏠 \(shortName)"
        default: return type
        }
    }
}

struct LargeWidgetView: View {
    let records: [SimpleRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Geographical Records")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            ForEach(records, id: \.type) { record in
                HStack {
                    Text(shortName(for: record.type))
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(record.value)
                        .font(.body)
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 2)
            }

            Spacer()
        }
        .padding()
    }

    private func shortName(for type: String) -> String {
        let shortName = FormatUtils.shortName(for: type)
        switch type {
        case "Furthest North": return "⬆️ Furthest \(shortName)"
        case "Furthest South": return "⬇️ Furthest \(shortName)"
        case "Furthest East": return "➡️ Furthest \(shortName)"
        case "Furthest West": return "⬅️ Furthest \(shortName)"
        case "Furthest Up": return "🏔 Furthest \(shortName)"
        case "Furthest Down": return "🏖 Furthest \(shortName)"
        case "Furthest from Home": return "🏠 \(shortName)"
        default: return type
        }
    }
}

// MARK: - Main Widget View
struct GeoRecordsWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: RecordEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(records: entry.records)
        case .systemMedium:
            MediumWidgetView(records: entry.records)
        case .systemLarge:
            LargeWidgetView(records: entry.records)
        default:
            MediumWidgetView(records: entry.records)
        }
    }
}

// MARK: - Widget Configuration
struct GeoRecordsWidget: Widget {
    let kind: String = "GeoRecordsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordProvider()) { entry in
            GeoRecordsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("GeoRecords")
        .description("View your current geographical records at a glance")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Widget Bundle
@main
struct GeoRecordsWidgetBundle: WidgetBundle {
    var body: some Widget {
        GeoRecordsWidget()
    }
}

// MARK: - Preview
struct GeoRecordsWidget_Previews: PreviewProvider {
    static var previews: some View {
        let sampleRecords = [
            SimpleRecord(type: "Furthest North", value: "45.52°"),
            SimpleRecord(type: "Furthest South", value: "35.23°"),
            SimpleRecord(type: "Furthest East", value: "-115.42°"),
            SimpleRecord(type: "Furthest West", value: "-122.68°"),
            SimpleRecord(type: "Furthest Up", value: "5,280 ft"),
            SimpleRecord(type: "Furthest Down", value: "-282 ft"),
            SimpleRecord(type: "Furthest from Home", value: "125.3 mi")
        ]

        GeoRecordsWidgetEntryView(entry: RecordEntry(date: Date(), records: sampleRecords))
            .previewContext(WidgetPreviewContext(family: .systemSmall))

        GeoRecordsWidgetEntryView(entry: RecordEntry(date: Date(), records: sampleRecords))
            .previewContext(WidgetPreviewContext(family: .systemMedium))

        GeoRecordsWidgetEntryView(entry: RecordEntry(date: Date(), records: sampleRecords))
            .previewContext(WidgetPreviewContext(family: .systemLarge))
    }
}
