import SwiftUI
import CoreData
import CoreLocation

struct HistoryView: View {
    @EnvironmentObject var settings: SettingsManager
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

    /// Pre-filtered entries using database predicate, with search applied in-memory
    private var filteredEntries: [RecordHistoryEntry] {
        var entries = Array(historyEntries)

        // Filter out records at home (likely test/bogus data)
        if let homeCoord = settings.homeCoordinate {
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            entries = entries.filter { entry in
                let entryLocation = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
                let distance = entryLocation.distance(from: homeLocation)
                return distance > atHomeRadiusMeters
            }
        }

        // Apply database-level filters first (record type and time frame)
        if let recordType = selectedRecordTypeFilter {
            entries = entries.filter { $0.recordType == recordType }
        }

        if let timeFrame = selectedTimeFrameFilter {
            entries = entries.filter { $0.timeFrame == timeFrame }
        }

        // Apply search filter
        if !searchText.isEmpty {
            entries = entries.filter { entry in
                let matchesRecordType = entry.recordType?.localizedCaseInsensitiveContains(searchText) ?? false
                let matchesLocation = entry.locationName?.localizedCaseInsensitiveContains(searchText) ?? false
                return matchesRecordType || matchesLocation
            }
        }

        return entries
    }

    private var activeFilterCount: Int {
        var count = 0
        if selectedRecordTypeFilter != nil { count += 1 }
        if selectedTimeFrameFilter != nil { count += 1 }
        return count
    }

    var body: some View {
        NavigationStack {
            Group {
                if historyEntries.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No History Yet")
                            .font(.headline)
                        Text("Your record history will appear here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 60)
                } else if filteredEntries.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Results")
                            .font(.headline)
                        Text("Try adjusting your search or filters.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 60)
                } else {
                    List(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink(destination: HistoryDetailPager(entries: filteredEntries, initialIndex: index)) {
                            CompactHistoryRow(entry: entry)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                    .listStyle(.plain)
                }
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

// MARK: - Compact History Row

struct CompactHistoryRow: View {
    let entry: RecordHistoryEntry
    @EnvironmentObject var settings: SettingsManager

    private var recordIcon: String {
        guard let type = entry.recordType else { return "location.circle.fill" }
        return FormatUtils.iconForRecordType(type)
    }

    private var iconColor: Color {
        guard let type = entry.recordType,
              let recordType = RecordType.from(string: type) else { return .gray }
        switch recordType {
        case .north: return .blue
        case .south: return .blue
        case .east: return .orange
        case .west: return .orange
        case .up: return .green
        case .fromHome: return .red
        }
    }

    private var timeFrameColor: Color {
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

    private var formattedValue: String {
        guard let detail = RecordDetail(from: entry) else { return "—" }
        return detail.formattedValue(unitSystem: settings.unitSystem)
    }

    private var locationText: String {
        if let name = entry.locationName, !name.isEmpty, name != unknownLocationString {
            return name
        }
        return String(format: "%.4f, %.4f", entry.latitude, entry.longitude)
    }

    private var formattedDate: String {
        guard let timestamp = entry.timestamp else { return "—" }
        return isoDateFormatter.string(from: timestamp)
    }

    private var formattedTime: String {
        guard let timestamp = entry.timestamp else { return "" }
        return time24Formatter.string(from: timestamp)
    }

    private var timeFrameAbbrev: String {
        guard let tf = entry.timeFrame else { return "?" }
        switch tf {
        case "Monthly": return "M"
        case "Yearly": return "Y"
        case "All-Time": return "A"
        default: return String(tf.prefix(1))
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Icon (same as Records tab)
            Image(systemName: recordIcon)
                .font(.system(size: 16))
                .foregroundColor(iconColor)
                .frame(width: 20)

            // Timeframe badge (styled to match icon aesthetic)
            Text(timeFrameAbbrev)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(timeFrameColor)
                )

            // Date/time stacked (date on top, time below, left justified)
            VStack(alignment: .leading, spacing: 0) {
                Text(formattedDate)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(formattedTime)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .frame(width: 68, alignment: .leading)

            // Location name
            Text(locationText)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Value
            Text(formattedValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Filter Option Button

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
