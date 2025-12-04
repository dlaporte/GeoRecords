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
        let detail = RecordDetail(
            value: entry.value,
            timestamp: entry.timestamp ?? Date(),
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? "Unknown"
        )
        return detail.formattedValue(unitSystem: SettingsManager.shared.unitSystem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.recordType ?? "Unknown")
                .font(.headline)
            Text(formattedValueForEntry())
                .font(.body)
                .foregroundColor(.secondary)
            if let timestamp = entry.timestamp {
                Text("\(timestamp, formatter: recordDateFormatter)")
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                Text("Unknown date")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
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
