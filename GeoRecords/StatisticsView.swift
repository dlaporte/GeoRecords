import SwiftUI
import CoreData
import CoreLocation

struct StatisticsView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @State private var stats: TravelStatistics?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let stats = stats {
                        // Overview Card
                        StatCard(title: "Overview") {
                            if let firstDate = stats.firstRecordDate {
                                StatRow(label: "Tracking Since", value: formatDate(firstDate))
                            }
                            StatRow(label: "New records this month", value: "\(stats.recordsThisMonth)")
                            StatRow(label: "New records this year", value: "\(stats.recordsThisYear)")
                        }

                        // Extremes Table Card
                        StatCard(title: "Extremes") {
                            ExtremesTable(recordManager: recordManager, settings: settings)
                        }
                    } else {
                        ProgressView("Loading statistics...")
                            .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Statistics")
            .onAppear {
                loadStatistics()
            }
        }
    }

    private func loadStatistics() {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            let entries = try context.fetch(request)
            let homeCoord = settings.homeCoordinate
            stats = TravelStatistics(from: entries, homeCoordinate: homeCoord)
        } catch {
            debugLog("Failed to load statistics: \(error)")
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Statistics Model
struct TravelStatistics {
    let firstRecordDate: Date?
    let recordsThisMonth: Int
    let recordsThisYear: Int

    init(from entries: [RecordHistoryEntry], homeCoordinate: CLLocationCoordinate2D?) {
        self.firstRecordDate = entries.first?.timestamp

        // Get current month and year boundaries
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let startOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now

        // Count records this month
        self.recordsThisMonth = entries.filter { entry in
            guard let timestamp = entry.timestamp else { return false }
            return timestamp >= startOfMonth
        }.count

        // Count records this year
        self.recordsThisYear = entries.filter { entry in
            guard let timestamp = entry.timestamp else { return false }
            return timestamp >= startOfYear
        }.count
    }
}

// MARK: - Extremes Table
struct ExtremesTable: View {
    let recordManager: RecordManager
    let settings: SettingsManager

    private let recordTypes = [
        "Furthest North",
        "Furthest South",
        "Furthest East",
        "Furthest West",
        "Furthest Up",
        "Furthest Down",
        "Furthest from Home"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                Text("")
                    .frame(width: 100, alignment: .leading)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.vertical, 8)

                Text("Month")
                    .frame(maxWidth: .infinity)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.vertical, 8)

                Text("Year")
                    .frame(maxWidth: .infinity)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.vertical, 8)

                Text("All Time")
                    .frame(maxWidth: .infinity)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.vertical, 8)
            }
            .background(Color(UIColor.tertiarySystemBackground))

            Divider()

            // Data rows
            ForEach(recordTypes, id: \.self) { type in
                ExtremesRow(
                    type: type,
                    monthValue: formatValue(recordManager.getRecord(type: type, timeFrame: .month)),
                    yearValue: formatValue(recordManager.getRecord(type: type, timeFrame: .year)),
                    allTimeValue: formatValue(recordManager.getRecord(type: type, timeFrame: .allTime))
                )
            }
        }
        .background(Color(UIColor.systemBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func formatValue(_ record: RecordDetail?) -> String {
        guard let record = record else { return "—" }
        return record.formattedValue(unitSystem: settings.unitSystem)
    }
}

struct ExtremesRow: View {
    let type: String
    let monthValue: String
    let yearValue: String
    let allTimeValue: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(iconForType(type))
                    .frame(width: 100, alignment: .leading)
                    .font(.caption)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)

                Text(monthValue)
                    .frame(maxWidth: .infinity)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)

                Text(yearValue)
                    .frame(maxWidth: .infinity)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)

                Text(allTimeValue)
                    .frame(maxWidth: .infinity)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)
            }
            .background(Color(UIColor.systemBackground))

            Divider()
        }
    }

    private func iconForType(_ type: String) -> String {
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

// MARK: - Reusable Components
struct StatCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
    }
}

struct StatisticsView_Previews: PreviewProvider {
    static var previews: some View {
        StatisticsView()
            .environmentObject(SettingsManager.shared)
            .environmentObject(RecordManager.shared)
    }
}
