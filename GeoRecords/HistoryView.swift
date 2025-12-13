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

    /// Build predicate for database-level filtering
    private var filterPredicate: NSPredicate? {
        var predicates: [NSPredicate] = []

        if let recordType = selectedRecordTypeFilter {
            predicates.append(NSPredicate(format: "recordType == %@", recordType))
        }

        if let timeFrame = selectedTimeFrameFilter {
            predicates.append(NSPredicate(format: "timeFrame == %@", timeFrame))
        }

        if predicates.isEmpty {
            return nil
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    /// Pre-filtered entries using database predicate, with search applied in-memory
    /// Note: Search is kept in-memory because CONTAINS is more flexible than database LIKE
    private var filteredEntries: [RecordHistoryEntry] {
        var entries = Array(historyEntries)

        // Apply database-level filters first (record type and time frame)
        if let recordType = selectedRecordTypeFilter {
            entries = entries.filter { $0.recordType == recordType }
        }

        if let timeFrame = selectedTimeFrameFilter {
            entries = entries.filter { $0.timeFrame == timeFrame }
        }

        // Apply search filter (kept in-memory for flexibility)
        if !searchText.isEmpty {
            entries = entries.filter { entry in
                let matchesRecordType = entry.recordType?.localizedCaseInsensitiveContains(searchText) ?? false
                let matchesLocation = entry.locationName?.localizedCaseInsensitiveContains(searchText) ?? false
                return matchesRecordType || matchesLocation
            }
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
        guard let detail = RecordDetail(from: entry) else {
            return "—"
        }
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

// MARK: - Filter Option Button

/// Reusable filter option button with checkmark indicator
private struct FilterOptionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
        .foregroundColor(.primary)
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
                    FilterOptionButton(
                        title: "All Types",
                        isSelected: selectedRecordType == nil,
                        action: { selectedRecordType = nil }
                    )

                    ForEach(availableRecordTypes, id: \.self) { type in
                        FilterOptionButton(
                            title: type,
                            isSelected: selectedRecordType == type,
                            action: { selectedRecordType = type }
                        )
                    }
                }

                Section(header: Text("Time Frame")) {
                    FilterOptionButton(
                        title: "All Time Frames",
                        isSelected: selectedTimeFrame == nil,
                        action: { selectedTimeFrame = nil }
                    )

                    ForEach(availableTimeFrames, id: \.self) { frame in
                        FilterOptionButton(
                            title: frame,
                            isSelected: selectedTimeFrame == frame,
                            action: { selectedTimeFrame = frame }
                        )
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
