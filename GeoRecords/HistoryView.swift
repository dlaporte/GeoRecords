import SwiftUI
import CoreData
import CoreLocation

struct HistoryView: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var searchText = ""
    @State private var selectedRecordTypeFilter: String = "All Types"
    @State private var selectedTimeFrameFilter: String = "All Timeframes"

    // Fetch history entries sorted by timestamp (newest first)
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \RecordHistoryEntry.timestamp, ascending: false)],
        animation: .default
    )
    private var historyEntries: FetchedResults<RecordHistoryEntry>

    /// Pre-filtered entries using database predicate, with search applied in-memory
    private var filteredEntries: [RecordHistoryEntry] {
        var entries = Array(historyEntries)

        // Filter out daily records (internal use only for "This Month" charts)
        entries = entries.filter { $0.timeFrame != TimeFrame.daily.rawValue }

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
        if selectedRecordTypeFilter != "All Types" {
            entries = entries.filter { $0.recordType == selectedRecordTypeFilter }
        }

        if selectedTimeFrameFilter != "All Timeframes" {
            entries = entries.filter { entry in
                // Treat all variations of lifetime records as the same
                if selectedTimeFrameFilter == canonicalLifetimeTimeFrame {
                    return lifetimeTimeFrameVariations.contains(entry.timeFrame ?? "")
                }
                return entry.timeFrame == selectedTimeFrameFilter
            }
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

    // Available filter options from the data
    private var availableRecordTypes: [String] {
        let types = Set(historyEntries.compactMap { $0.recordType })
        return ["All Types"] + types.sorted()
    }

    // Region types don't have timeframe variations
    private func isRegionType(_ type: String) -> Bool {
        RecordType.from(string: type)?.isRegionVisit ?? false
    }

    private var isRegionTypeSelected: Bool {
        isRegionType(selectedRecordTypeFilter)
    }

    private var availableTimeFrames: [String] {
        var frames = Set(historyEntries.compactMap { $0.timeFrame })

        // Remove Daily - it's for internal chart use only
        frames.remove("Daily")

        // Merge all variations of all-time/lifetime into single canonical "Lifetime" option
        let hasLifetime = frames.contains(where: { lifetimeTimeFrameVariations.contains($0) })

        if hasLifetime {
            lifetimeTimeFrameVariations.forEach { frames.remove($0) }
            frames.insert(canonicalLifetimeTimeFrame)
        }

        // Sort in logical order: Lifetime, Yearly, Monthly
        let sortOrder = ["Lifetime", "Yearly", "Monthly"]
        let sortedFrames = frames.sorted { f1, f2 in
            let idx1 = sortOrder.firstIndex(of: f1) ?? sortOrder.count
            let idx2 = sortOrder.firstIndex(of: f2) ?? sortOrder.count
            return idx1 < idx2
        }

        return ["All Timeframes"] + sortedFrames
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter controls
                VStack(spacing: 12) {
                    // Pickers row
                    HStack(spacing: 12) {
                        // Record type picker
                        Picker("Type", selection: $selectedRecordTypeFilter) {
                            ForEach(availableRecordTypes, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)

                        // Time frame picker (disabled for region types which don't have timeframes)
                        Picker("Time Frame", selection: $selectedTimeFrameFilter) {
                            ForEach(availableTimeFrames, id: \.self) { frame in
                                Text(frame).tag(frame)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                        .disabled(isRegionTypeSelected)
                        .opacity(isRegionTypeSelected ? 0.5 : 1.0)
                        .onChange(of: selectedRecordTypeFilter) { _, newValue in
                            // Reset to All Timeframes when selecting a region type
                            if isRegionType(newValue) {
                                selectedTimeFrameFilter = "All Timeframes"
                            }
                        }
                    }

                    // Search field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search by type or location", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(8)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(Color(UIColor.systemBackground))

                Divider()

                // Content
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
            .navigationTitle("History (\(filteredEntries.count))")
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
        guard let type = entry.recordType else { return .gray }
        return FormatUtils.colorForRecordType(type)
    }

    private var timeFrameColor: Color {
        guard let timeFrameString = entry.timeFrame else {
            return .gray
        }
        // Handle lifetime variations
        if lifetimeTimeFrameVariations.contains(timeFrameString) {
            return TimeFrame.allTime.color
        }
        // Use centralized color property
        return TimeFrame(rawValue: timeFrameString)?.color ?? .gray
    }

    private var formattedValue: String {
        guard let detail = RecordDetail(from: entry) else { return "—" }
        return detail.formattedValue(unitSystem: settings.unitSystem)
    }

    private var locationText: String {
        if let name = entry.locationName, !name.isEmpty, name != unknownLocationString {
            // Add flag for countries
            if let recordType = entry.recordType,
               let flag = FormatUtils.flagEmoji(for: entry.regionCode, recordType: recordType) {
                return "\(flag) \(name)"
            }
            return name
        }
        return FormatUtils.formatCoordinates(entry.latitude, entry.longitude)
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
        // Handle lifetime variations
        if lifetimeTimeFrameVariations.contains(tf) {
            return TimeFrame.allTime.abbreviation
        }
        // Use centralized abbreviation property
        return TimeFrame(rawValue: tf)?.abbreviation ?? String(tf.prefix(1))
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

