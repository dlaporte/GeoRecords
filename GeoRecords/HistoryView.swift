import SwiftUI
import CoreData
import CoreLocation

struct HistoryView: View {
    @State private var pageSize = 50
    @State private var isShowingAll = false
    @State private var searchText = ""
    @State private var selectedRecordTypeFilter: String? = nil
    @State private var selectedTimeFrameFilter: String? = nil
    @State private var showFilterSheet = false

    // Fetch history entries sorted by timestamp (newest first)
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \RecordHistoryEntry.timestamp, ascending: false)],
        animation: .default
    )
    private var historyEntries: FetchedResults<RecordHistoryEntry>

    private var filteredEntries: [RecordHistoryEntry] {
        var entries = Array(historyEntries)

        // Apply search filter
        if !searchText.isEmpty {
            entries = entries.filter { entry in
                let matchesRecordType = entry.recordType?.localizedCaseInsensitiveContains(searchText) ?? false
                let matchesLocation = entry.locationName?.localizedCaseInsensitiveContains(searchText) ?? false
                return matchesRecordType || matchesLocation
            }
        }

        // Apply record type filter
        if let recordType = selectedRecordTypeFilter {
            entries = entries.filter { $0.recordType == recordType }
        }

        // Apply time frame filter
        if let timeFrame = selectedTimeFrameFilter {
            entries = entries.filter { $0.timeFrame == timeFrame }
        }

        return entries
    }

    private var displayedEntries: [RecordHistoryEntry] {
        if isShowingAll {
            return filteredEntries
        } else {
            return Array(filteredEntries.prefix(pageSize))
        }
    }

    private var activeFilterCount: Int {
        var count = 0
        if selectedRecordTypeFilter != nil { count += 1 }
        if selectedTimeFrameFilter != nil { count += 1 }
        return count
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
                        if displayedEntries.isEmpty {
                            Text("No results found")
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                        } else {
                            ForEach(displayedEntries) { entry in
                                NavigationLink(destination: HistoryDetailView(entry: entry)) {
                                    HistoryCard(entry: entry)
                                }
                            }

                            // Show "Load More" button if there are more entries
                            if !isShowingAll && filteredEntries.count > pageSize {
                                Button(action: {
                                    pageSize += 50
                                    if pageSize >= filteredEntries.count {
                                        isShowingAll = true
                                    }
                                }) {
                                    HStack {
                                        Text("Load More")
                                        Text("(\(filteredEntries.count - pageSize) remaining)")
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
                }
                .padding()
            }
            .navigationTitle("History (\(filteredEntries.count))")
            .searchable(text: $searchText, prompt: "Search by type or location")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showFilterSheet = true
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            if activeFilterCount > 0 {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                FilterSheet(
                    selectedRecordType: $selectedRecordTypeFilter,
                    selectedTimeFrame: $selectedTimeFrameFilter,
                    historyEntries: historyEntries
                )
            }
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
                        Text(compactDateFormatter.string(from: timestamp))
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

// MARK: - Filter Sheet
struct FilterSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var selectedRecordType: String?
    @Binding var selectedTimeFrame: String?
    let historyEntries: FetchedResults<RecordHistoryEntry>

    private var availableRecordTypes: [String] {
        let types = Set(historyEntries.compactMap { $0.recordType })
        return types.sorted()
    }

    private var availableTimeFrames: [String] {
        let frames = Set(historyEntries.compactMap { $0.timeFrame })
        return frames.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Record Type")) {
                    Button(action: {
                        selectedRecordType = nil
                    }) {
                        HStack {
                            Text("All Types")
                            Spacer()
                            if selectedRecordType == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .foregroundColor(.primary)

                    ForEach(availableRecordTypes, id: \.self) { type in
                        Button(action: {
                            selectedRecordType = type
                        }) {
                            HStack {
                                Text(type)
                                Spacer()
                                if selectedRecordType == type {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }

                Section(header: Text("Time Frame")) {
                    Button(action: {
                        selectedTimeFrame = nil
                    }) {
                        HStack {
                            Text("All Time Frames")
                            Spacer()
                            if selectedTimeFrame == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .foregroundColor(.primary)

                    ForEach(availableTimeFrames, id: \.self) { frame in
                        Button(action: {
                            selectedTimeFrame = frame
                        }) {
                            HStack {
                                Text(frame)
                                Spacer()
                                if selectedTimeFrame == frame {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }

                Section {
                    Button(action: {
                        selectedRecordType = nil
                        selectedTimeFrame = nil
                    }) {
                        Text("Clear All Filters")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Filter History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
