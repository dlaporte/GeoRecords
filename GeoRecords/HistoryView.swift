import SwiftUI
import CoreData
import CoreLocation

struct HistoryView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @Environment(HistoryTabState.self) private var state
    @State private var pendingDelete: RecordHistoryEntry?

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

        // Filter out records at home (likely test/bogus data) unless asked to show them
        if !state.includeHome, let homeCoord = settings.homeCoordinate {
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            entries = entries.filter { entry in
                let entryLocation = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
                let distance = entryLocation.distance(from: homeLocation)
                return distance > atHomeRadiusMeters
            }
        }

        // Apply database-level filters first (record type, time frame, source)
        if state.typeFilter != "All Types" {
            entries = entries.filter { $0.recordType == state.typeFilter }
        }

        if state.source != .all {
            entries = entries.filter { state.source.matches($0.source) }
        }

        if state.timeFrameFilter != "All Timeframes" {
            entries = entries.filter { entry in
                // Treat all variations of lifetime records as the same
                if state.timeFrameFilter == canonicalLifetimeTimeFrame {
                    return lifetimeTimeFrameVariations.contains(entry.timeFrame ?? "")
                }
                return entry.timeFrame == state.timeFrameFilter
            }
        }

        // Apply search filter
        if !state.searchText.isEmpty {
            entries = entries.filter { entry in
                let matchesRecordType = entry.recordType?.localizedCaseInsensitiveContains(state.searchText) ?? false
                let matchesLocation = entry.locationName?.localizedCaseInsensitiveContains(state.searchText) ?? false
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
        isRegionType(state.typeFilter)
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

    /// Month sections over the flat filtered list (rows keep their pager index)
    private var sections: [HistorySection] {
        HistorySections.group(filteredEntries)
    }

    private var hasActiveFilters: Bool {
        !state.searchText.isEmpty || state.typeFilter != "All Types"
            || state.timeFrameFilter != "All Timeframes" || state.source != .all
    }

    /// Everything is hidden only by the at-home rule: say so instead of "No Results"
    private var onlyHomeRowsRemain: Bool {
        filteredEntries.isEmpty && !state.includeHome && !hasActiveFilters
            && historyEntries.contains { $0.timeFrame != TimeFrame.daily.rawValue }
    }

    private func deleteEntry(_ entry: RecordHistoryEntry) {
        guard let detail = RecordDetail(from: entry) else { return }
        deleteRecordFromStorage(detail, recordManager: recordManager)
    }

    @Environment(\.layoutWidth) private var layoutWidth
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var state = state
        Group {
            if layoutWidth == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .alert("Delete Record?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) {
                deleteEntry(entry)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(RecordDeleteCopy.message(recordType: entry.recordType))
        }
        // ⌘F focuses the search field with a hardware keyboard
        .background {
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Layouts

    /// iPhone: filters above a list whose rows push the detail pager
    private var compactLayout: some View {
        @Bindable var state = state
        return NavigationStack {
            VStack(spacing: 0) {
                filterControls
                Divider()
                compactContent
            }
            .searchable(text: $state.searchText, prompt: "Type or place")
            .searchFocused($isSearchFocused)
            .navigationTitle("History (\(filteredEntries.count))")
        }
    }

    /// iPad, iPhone Duo open, Max phones in landscape: the list beside the
    /// selected entry's detail, with previous/next in the detail toolbar
    private var regularLayout: some View {
        @Bindable var state = state
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                filterControls
                Divider()
                regularContent
            }
            .searchable(text: $state.searchText, prompt: "Type or place")
            .searchFocused($isSearchFocused)
            .navigationTitle("History (\(filteredEntries.count))")
            .navigationSplitViewColumnWidth(SidebarWidth(minimum: 380, ideal: 440, maximum: 540))
        } detail: {
            if let entry = focusedEntry {
                HistoryDetailPane(entries: filteredEntries, selectedID: $state.selectedEntryID, current: entry)
                    .id(entry.objectID)
            } else {
                ContentUnavailableView("No Record Selected", systemImage: "clock", description: Text("Choose a record from the list."))
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Selection with a default: the first entry stands in for "nothing chosen yet"
    private var listSelection: Binding<UUID?> {
        Binding(
            get: { focusedEntry?.id },
            set: { state.selectedEntryID = $0 }
        )
    }

    /// The entry the detail column shows: the hoisted selection when it is still in
    /// the filtered list, else the first entry
    private var focusedEntry: RecordHistoryEntry? {
        let entries = filteredEntries
        if let id = state.selectedEntryID, let entry = entries.first(where: { $0.id == id }) {
            return entry
        }
        return entries.first
    }

    private var filterControls: some View {
        @Bindable var state = state
        return Group {
            // Filter controls
            VStack(spacing: 12) {
                // Type and source (the two short menus share a row)
                HStack(spacing: 12) {
                    FilterMenu(title: state.typeFilter) {
                        Picker("Type", selection: $state.typeFilter) {
                            ForEach(availableRecordTypes, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }
                    }
                    .onChange(of: state.typeFilter) { _, newValue in
                        // Reset to All Timeframes when selecting a region type
                        if isRegionType(newValue) {
                            state.timeFrameFilter = "All Timeframes"
                        }
                    }

                    FilterMenu(title: state.source.title) {
                        Picker("Source", selection: $state.source) {
                            ForEach(HistorySourceFilter.menuOrder, id: \.self) { source in
                                Text(source.title).tag(source)
                            }
                        }
                    }
                }

                // Timeframe (disabled for region types, which have none) and the
                // at-home rows, normally hidden
                HStack(spacing: 12) {
                    FilterMenu(title: state.timeFrameFilter) {
                        Picker("Time Frame", selection: $state.timeFrameFilter) {
                            ForEach(availableTimeFrames, id: \.self) { frame in
                                Text(frame).tag(frame)
                            }
                        }
                    }
                    .disabled(isRegionTypeSelected)
                    .opacity(isRegionTypeSelected ? 0.5 : 1.0)

                    Toggle("Include home", isOn: $state.includeHome)
                        .toggleStyle(.switch)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))
        }
    }

    private var compactContent: some View {
        Group {
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
                } else if onlyHomeRowsRemain {
                    VStack(spacing: 16) {
                        Image(systemName: "house")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Everything Is at Home")
                            .font(.headline)
                        Text("All of your records are at home. Turn on Include home to see them.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
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
                    let entries = filteredEntries
                    List {
                        ForEach(sections) { section in
                            Section(header: Text(section.title)) {
                                ForEach(section.rows) { row in
                                    NavigationLink(destination: HistoryDetailPager(entries: entries, initialIndex: row.index)) {
                                        CompactHistoryRow(entry: row.entry)
                                    }
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDelete = row.entry
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    private var regularContent: some View {
        Group {
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
                } else if onlyHomeRowsRemain {
                    VStack(spacing: 16) {
                        Image(systemName: "house")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Everything Is at Home")
                            .font(.headline)
                        Text("All of your records are at home. Turn on Include home to see them.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
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
                    List(selection: listSelection) {
                        ForEach(sections) { section in
                            Section(header: Text(section.title)) {
                                ForEach(section.rows) { row in
                                    CompactHistoryRow(entry: row.entry)
                                        .tag(row.entry.id ?? UUID())
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDelete = row.entry
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Filter Menu

/// A menu picker whose label is the current choice on one line. A plain
/// `.pickerStyle(.menu)` sizes itself for its longest option and wraps the label
/// when it shares a row.
private struct FilterMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity)
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
        return FormatUtils.formatCoordinatesWithCardinals(
            CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude)
        )
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

            // Value ("117.4260° W" is wider than the old signed form; never wrap it)
            Text(formattedValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 82, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

