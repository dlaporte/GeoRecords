import SwiftUI
import CoreData
import CoreLocation

struct HistoryView: View {
    @State private var pageSize = 50
    @State private var isShowingAll = false

    // Fetch history entries sorted by timestamp (newest first)
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \RecordHistoryEntry.timestamp, ascending: false)],
        animation: .default
    )
    private var historyEntries: FetchedResults<RecordHistoryEntry>

    private var displayedEntries: [RecordHistoryEntry] {
        if isShowingAll {
            return Array(historyEntries)
        } else {
            return Array(historyEntries.prefix(pageSize))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if historyEntries.isEmpty {
                        Text("No history available")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    } else {
                        ForEach(displayedEntries) { entry in
                            NavigationLink(destination: HistoryDetailView(entry: entry)) {
                                HistoryCard(entry: entry)
                            }
                        }

                        // Show "Load More" button if there are more entries
                        if !isShowingAll && historyEntries.count > pageSize {
                            Button(action: {
                                pageSize += 50
                                if pageSize >= historyEntries.count {
                                    isShowingAll = true
                                }
                            }) {
                                HStack {
                                    Text("Load More")
                                    Text("(\(historyEntries.count - pageSize) remaining)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(10)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("History (\(historyEntries.count))")
        }
    }
}

struct HistoryCard: View {
    let entry: RecordHistoryEntry

    private func formattedValueForEntry() -> String {
        // Convert Core Data entry to RecordDetail to reuse formatting logic
        let timeFrame: TimeFrame = {
            if let timeFrameString = entry.timeFrame {
                return TimeFrame(rawValue: timeFrameString) ?? .allTime
            }
            return .allTime  // Default for old entries without timeFrame
        }()

        let detail = RecordDetail(
            value: entry.value,
            timestamp: entry.timestamp ?? Date(),
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? "Unknown",
            timeFrame: timeFrame
        )
        return detail.formattedValue(unitSystem: SettingsManager.shared.unitSystem)
    }

    private func timeFrameColor() -> Color {
        guard let timeFrameString = entry.timeFrame,
              let timeFrame = TimeFrame(rawValue: timeFrameString) else {
            return .gray
        }
        switch timeFrame {
        case .month: return .green
        case .year: return .orange
        case .allTime: return .blue
        }
    }

    private func compactDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy HH:mm"
        return formatter
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Timeframe badge
            if let timeFrameString = entry.timeFrame {
                Text(timeFrameString)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(timeFrameColor().opacity(0.2))
                    .foregroundColor(timeFrameColor())
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.recordType ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Location name if available
                if let locationName = entry.locationName, !locationName.isEmpty {
                    Text(locationName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(formattedValueForEntry())
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let timestamp = entry.timestamp {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(compactDateFormatter().string(from: timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(UIColor.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        )
    }
}
