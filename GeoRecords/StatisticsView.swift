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
                            if let daysSinceFirst = stats.daysSinceFirstRecord {
                                StatRow(label: "Days Tracking", value: "\(daysSinceFirst)")
                            }
                            StatRow(label: "Total Records", value: "\(stats.totalRecords)")
                            StatRow(label: "Records Broken", value: "\(stats.recordsCount)")
                            if let firstDate = stats.firstRecordDate {
                                StatRow(label: "Tracking Since", value: formatDate(firstDate))
                            }
                        }

                        // Distance & Altitude Card
                        StatCard(title: "Extremes") {
                            if let latRange = stats.latitudeRange {
                                StatRow(label: "Latitude Range", value: String(format: "%.2f°", latRange))
                            }
                            if let lonRange = stats.longitudeRange {
                                StatRow(label: "Longitude Range", value: String(format: "%.2f°", lonRange))
                            }
                            if let altRange = stats.altitudeRange {
                                if settings.unitSystem == .imperial {
                                    let feet = altRange * 3.28084
                                    StatRow(label: "Altitude Range", value: String(format: "%.0f ft", feet))
                                } else {
                                    StatRow(label: "Altitude Range", value: String(format: "%.0f m", altRange))
                                }
                            }
                        }

                        // From Home Card
                        if let maxDistance = stats.maxDistanceFromHome, settings.homeCoordinate != nil {
                            StatCard(title: "From Home") {
                                if settings.unitSystem == .imperial {
                                    let miles = maxDistance / 1609.344
                                    StatRow(label: "Furthest Distance", value: String(format: "%.2f mi", miles))
                                } else {
                                    let km = maxDistance / 1000.0
                                    StatRow(label: "Furthest Distance", value: String(format: "%.2f km", km))
                                }
                            }
                        }

                        // Record Breakdown Card
                        StatCard(title: "Records by Type") {
                            let orderedTypes = [
                                "Furthest North",
                                "Furthest South",
                                "Furthest East",
                                "Furthest West",
                                "Furthest Up",
                                "Furthest Down",
                                "Furthest from Home"
                            ]
                            ForEach(orderedTypes, id: \.self) { type in
                                if let count = stats.recordsByType[type] {
                                    StatRow(label: shortName(for: type), value: "\(count)")
                                }
                            }
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

// MARK: - Statistics Model
struct TravelStatistics {
    let totalRecords: Int
    let recordsCount: Int
    let firstRecordDate: Date?
    let latitudeRange: Double?
    let longitudeRange: Double?
    let altitudeRange: Double?
    let maxDistanceFromHome: Double?
    let recordsByType: [String: Int]
    let daysSinceFirstRecord: Int?
    let averageRecordsPerMonth: Double?

    init(from entries: [RecordHistoryEntry], homeCoordinate: CLLocationCoordinate2D?) {
        self.totalRecords = entries.count
        self.firstRecordDate = entries.first?.timestamp

        // Count records by type
        var typeCount: [String: Int] = [:]
        for entry in entries {
            if let type = entry.recordType {
                typeCount[type, default: 0] += 1
            }
        }
        self.recordsByType = typeCount
        self.recordsCount = typeCount.count

        // Calculate latitude range
        let latitudes = entries.map { $0.latitude }
        if let minLat = latitudes.min(), let maxLat = latitudes.max() {
            self.latitudeRange = maxLat - minLat
        } else {
            self.latitudeRange = nil
        }

        // Calculate longitude range
        let longitudes = entries.map { $0.longitude }
        if let minLon = longitudes.min(), let maxLon = longitudes.max() {
            self.longitudeRange = maxLon - minLon
        } else {
            self.longitudeRange = nil
        }

        // Calculate altitude range
        let altitudes = entries.map { $0.altitude }
        if let minAlt = altitudes.min(), let maxAlt = altitudes.max() {
            self.altitudeRange = maxAlt - minAlt
        } else {
            self.altitudeRange = nil
        }

        // Calculate max distance from home
        if let homeCoord = homeCoordinate {
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let distances = entries.map { entry in
                let recordLocation = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
                return recordLocation.distance(from: homeLocation)
            }
            self.maxDistanceFromHome = distances.max()
        } else {
            self.maxDistanceFromHome = nil
        }

        // Calculate days since first record
        if let firstDate = firstRecordDate {
            self.daysSinceFirstRecord = Calendar.current.dateComponents([.day], from: firstDate, to: Date()).day
        } else {
            self.daysSinceFirstRecord = nil
        }

        // Calculate average records per month
        if let days = daysSinceFirstRecord, days > 0 {
            let months = Double(days) / 30.0
            self.averageRecordsPerMonth = Double(entries.count) / max(months, 1.0)
        } else {
            self.averageRecordsPerMonth = nil
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
