import SwiftUI
import MapKit
import CoreData

// MARK: - Notifications

extension Notification.Name {
    static let navigateToiCloudSync = Notification.Name("navigateToiCloudSync")
    static let scrollToiCloudSync = Notification.Name("scrollToiCloudSync")
    /// Stats' "Set Home Location" button: switch to Settings, then push the home picker
    static let navigateToHomePicker = Notification.Name("navigateToHomePicker")
    static let openHomePicker = Notification.Name("openHomePicker")
    static let showSetupWizard = Notification.Name("showSetupWizard")
    static let statisticsDidChange = Notification.Name("statisticsDidChange")
    static let recordsDidChange = Notification.Name("recordsDidChange")
    /// Posted after Delete All Records; ContentView runs the restore-first gate
    static let dataRestoreCheckNeeded = Notification.Name("dataRestoreCheckNeeded")
}

// MARK: - Layout Constants

private let mapHeightRatio: CGFloat = 0.5
private let cardHeightOffset: CGFloat = 100

struct RecordsView: View {
    @EnvironmentObject var recordManager: RecordManager
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var deepLinkManager: DeepLinkManager
    @ObservedObject private var persistenceController = PersistenceController.shared

    @State private var navigateToDetail = false
    @State private var selectedRecordIndex: Int = 0
    @State private var currentRecordIndex = 0
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedMarkerRecordId: UUID?
    @Environment(RecordsTabState.self) private var state
    @State private var availableYears: [Int] = []
    @State private var availableMonths: [MonthSelection] = []

    /// Which slot the cards stand in, so a card can say "15 mi short of your yearly…"
    /// only on This Month and compute progression against the right period
    private var cardContext: RecordCardContext {
        let isCurrentPeriod: Bool
        switch state.timeFrame {
        case .month: isCurrentPeriod = state.month == nil
        case .year: isCurrentPeriod = state.year == nil
        default: isCurrentPeriod = true
        }
        return RecordCardContext(slotTimeFrame: state.timeFrame, isCurrentPeriod: isCurrentPeriod)
    }

    // Computed property to get all non-nil records in order for the selected timeframe
    // Only includes geographic extreme records (N/S/E/W/Up/FromHome), not region records
    // (recomputes via recordManager's objectWillChange - no manual invalidation needed)
    private var allRecords: [RecordDetail] {
        // For Year mode with a specific year selected, fetch best records from that year
        if state.timeFrame == .year, let year = state.year {
            return fetchRecordsForYear(year).filter { record in
                RecordType.from(string: record.recordType)?.isGeographicExtreme ?? false
            }
        }

        // For Month mode with a specific past month selected, fetch that month's records
        if state.timeFrame == .month, let month = state.month {
            return fetchRecordsForMonth(month).filter { record in
                RecordType.from(string: record.recordType)?.isGeographicExtreme ?? false
            }
        }

        // Otherwise show current timeframe records (only geographic extremes, not regions)
        return RecordType.allCases
            .filter { $0.isGeographicExtreme }
            .compactMap { type in
                recordManager.getRecord(type: type.rawValue, timeFrame: state.timeFrame)
            }
    }

    @Environment(\.layoutWidth) private var layoutWidth
    @Environment(\.cardSizing) private var sizing
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if layoutWidth == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .onChange(of: state.timeFrame) { _, newValue in
            // Reset historical selections when switching away from their timeframe
            if newValue != .year {
                state.year = nil
            }
            if newValue != .month {
                state.month = nil
            }

            // Clear badge for this timeframe since user is viewing it
            recordManager.clearBadge(for: newValue)

            // Update map when timeframe changes
            if let record = focusedRecord {
                centerMap(on: record)
            }
        }
        .onChange(of: state.year) { _, _ in
            resetToFirstRecord()
        }
        .onChange(of: state.month) { _, _ in
            resetToFirstRecord()
        }
        .onChange(of: state.selectedRecordID) { _, newID in
            // Regular-width selection drives the carousel index too, so folding a
            // Duo or shrinking a Split View lands on the same card
            guard let newID, let index = allRecords.firstIndex(where: { $0.id == newID }) else { return }
            if index != currentRecordIndex {
                currentRecordIndex = index
            }
            selectedMarkerRecordId = newID
            if let record = allRecords[safe: index] {
                centerMap(on: record)
            }
        }
        .onAppear {
            loadAvailableYears()
            loadAvailableMonths()
            handleDeepLink()
            // Clear badge for the currently selected timeframe
            recordManager.clearBadge(for: state.timeFrame)
            // Land on the hoisted selection (or the first record) and frame it
            if let selected = state.selectedRecordID, let index = allRecords.firstIndex(where: { $0.id == selected }) {
                currentRecordIndex = index
            }
            if let record = focusedRecord {
                mapPosition = .centered(on: record.coordinate, latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
            }
        }
        .onChange(of: deepLinkManager.recordType) { _, _ in
            handleDeepLink()
        }
        .onChange(of: deepLinkManager.navigateToRecordsTimeFrame) { _, _ in
            handleDeepLink()
        }
        .task(id: deepLinkManager.navigateToRecordsTimeFrame) {
            // Also handle via task to catch cases where onChange doesn't fire
            if deepLinkManager.navigateToRecordsTimeFrame != nil {
                handleDeepLink()
            }
        }
        .onChange(of: persistenceController.lastImportTime) { _, newTime in
            // Refresh records when iCloud import completes
            if newTime != nil {
                debugLog("☁️ RecordsView: iCloud import detected, reloading records")
                recordManager.loadRecordsFromHistory()
                loadAvailableYears()
                loadAvailableMonths()
                // loadRecordsFromHistory is synchronous and publishes the change,
                // so allRecords is already fresh here
                if let firstRecord = allRecords.first {
                    centerMap(on: firstRecord)
                }
            }
        }
    }

    // MARK: - Layouts

    /// iPhone (and any compact-width window): picker, map, swipeable cards, push to
    /// detail. In compact height (a phone in landscape) the map sits beside the
    /// cards; stacked, the 280-pt card strip left the map no room at all
    private var compactLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                timeFramePicker
                    .padding()

                if allRecords.isEmpty {
                    emptyState
                } else if sizing.isCompact {
                    HStack(spacing: 0) {
                        recordsMap
                        cardCarousel
                            .frame(width: 360)
                    }
                } else {
                    recordsMap
                    cardCarousel
                }
            }
            .navigationTitle("Records")
            .toolbar { syncToolbar }
            .navigationDestination(isPresented: $navigateToDetail) {
                RecordDetailPager(records: allRecords, initialIndex: selectedRecordIndex)
            }
        }
    }

    /// iPad, iPhone Duo open, Max phones in landscape: the cards as a selectable list
    /// beside a map that frames the selection, with the record's detail beneath the map
    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                timeFramePicker
                    .padding()
                if allRecords.isEmpty {
                    emptyState
                } else {
                    recordList
                }
            }
            .navigationTitle("Records")
            .toolbar { syncToolbar }
            .navigationSplitViewColumnWidth(SidebarWidth(minimum: 340, ideal: 380, maximum: 440))
        } detail: {
            if let record = focusedRecord {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        recordsMap
                            .frame(height: geometry.size.height * 0.45)
                        RecordDetailView(record: record)
                            .id(record.id)
                    }
                }
            } else {
                ContentUnavailableView("No Record Selected", systemImage: "location.north", description: Text("Choose a record from the list."))
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var timeFramePicker: some View {
        @Bindable var state = state
        return TimeFramePickerWithBadges(
            selectedTimeFrame: $state.timeFrame,
            selectedYear: $state.year,
            selectedMonth: $state.month,
            availableYears: availableYears,
            availableMonths: availableMonths,
            timeFrameLabel: { timeFrame in
                switch timeFrame {
                case .daily: return "Daily"
                case .allTime: return "Lifetime"
                case .year:
                    if let year = state.year {
                        return String(format: "%d", year)
                    }
                    return "This Year"
                case .month:
                    if let month = state.month {
                        return month.displayName
                    }
                    return "This Month"
                }
            },
            badgeCount: { timeFrame in
                switch timeFrame {
                case .daily:
                    return 0  // No badge for daily records
                case .month:
                    return recordManager.newMonthlyRecordCount
                case .year:
                    return recordManager.newYearlyRecordCount
                case .allTime:
                    return recordManager.newAllTimeRecordCount
                }
            }
        )
    }

    /// Empty state - show different content if syncing
    private var emptyState: some View {
        VStack(spacing: 20) {
            if persistenceController.isSyncing {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.bottom, 8)
                Text("Syncing from iCloud")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Your records are being downloaded from iCloud. This may take a moment...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Image(systemName: "map")
                    .font(.system(size: 60))
                    .foregroundColor(.gray)
                Text("No Records Yet")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Start exploring to set your first geographical record!")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Map of every record in the slot; tapping a marker selects that record
    private var recordsMap: some View {
        Map(position: $mapPosition, selection: $selectedMarkerRecordId) {
            ForEach(allRecords, id: \.id) { record in
                Marker(record.recordType, coordinate: record.coordinate)
                    .tint(FormatUtils.colorForRecordType(record.recordType))
                    .tag(record.id)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: selectedMarkerRecordId) { _, newId in
            guard let newId = newId,
                  let index = allRecords.firstIndex(where: { $0.id == newId }) else { return }
            if index != currentRecordIndex {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentRecordIndex = index
                }
            }
            if state.selectedRecordID != newId {
                state.selectedRecordID = newId
            }
        }
    }

    /// Swipeable cards (compact width); swiping frames the record on the map
    private var cardCarousel: some View {
        TabView(selection: $currentRecordIndex) {
            ForEach(Array(allRecords.enumerated()), id: \.element.id) { index, record in
                RecordCardView(record: record, context: cardContext)
                    .tag(index)
                    .onTapGesture {
                        selectedRecordIndex = index
                        navigateToDetail = true
                    }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .contentMargins(0, for: .scrollContent)
        .frame(maxWidth: .infinity)
        .frame(height: cardTabViewHeight)
        .padding(.vertical, 10)
        .onChange(of: currentRecordIndex) { _, newIndex in
            // Update map when swiping to new record, and keep the matching
            // marker highlighted (no loop: marker-tap and swipe both converge
            // on the same id/index, so the mirrored onChange sees no change)
            if let record = allRecords[safe: newIndex] {
                selectedMarkerRecordId = record.id
                state.selectedRecordID = record.id
                centerMap(on: record)
            }
        }
    }

    /// The cards as a scrolling stack (regular width); tapping one drives the detail
    /// column. Not a List: list selection repaints the selected card's text white
    /// and adds its own focus rectangle, so the ring below marks the selection
    private var recordList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(allRecords, id: \.id) { record in
                        Button {
                            state.selectedRecordID = record.id
                        } label: {
                            RecordCardView(record: record, context: cardContext)
                                .overlay {
                                    if focusedRecord?.id == record.id {
                                        RoundedRectangle(cornerRadius: sizing.isCompact ? 16 : 20)
                                            .strokeBorder(Color.accentColor, lineWidth: 3)
                                            .padding(.horizontal, sizing.horizontalPadding)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                        .accessibilityAddTraits(focusedRecord?.id == record.id ? .isSelected : [])
                        .id(record.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: state.selectedRecordID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// The record the map frames and the detail column shows: the hoisted selection
    /// when it is still in the slot, else the carousel's card, else the first record
    private var focusedRecord: RecordDetail? {
        if let id = state.selectedRecordID, let record = allRecords.first(where: { $0.id == id }) {
            return record
        }
        return allRecords[safe: currentRecordIndex] ?? allRecords.first
    }

    private func centerMap(on record: RecordDetail) {
        withAnimation {
            mapPosition = .centered(on: record.coordinate, latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
        }
    }

    @ToolbarContentBuilder
    private var syncToolbar: some ToolbarContent {
        // Show sync indicator when iCloud is syncing - tapping goes to iCloud Sync section
        if persistenceController.isSyncing {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    NotificationCenter.default.post(name: .navigateToiCloudSync, object: nil)
                } label: {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
    }

    private func handleDeepLink() {
        // Handle timeframe deep link from widgets and notifications
        if let timeFrame = deepLinkManager.navigateToRecordsTimeFrame {
            // A deep link targets the CURRENT period; apply() also clears any
            // historical year/month browsing even when the timeframe is unchanged
            state.apply(deepLinkTimeFrame: timeFrame)
            deepLinkManager.navigateToRecordsTimeFrame = nil
        }

        // Handle record type deep link from notifications
        guard let recordType = deepLinkManager.recordType else { return }

        // Deep links from notifications - find the record in allRecords.
        // Consume the link either way: a record that no longer exists (e.g. a
        // monthly record after the month rolled over) must not leave a stale
        // link that pops open an unrelated detail view on a later visit
        deepLinkManager.recordType = nil
        if let index = allRecords.firstIndex(where: { $0.recordType == recordType }) {
            selectedRecordIndex = index
            navigateToDetail = true
        }
    }

    /// Jump the carousel and map back to the first record (used when the year/month changes)
    private func resetToFirstRecord() {
        currentRecordIndex = 0
        state.selectedRecordID = allRecords.first?.id
        if let record = allRecords.first {
            withAnimation {
                mapPosition = .centered(on: record.coordinate, latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
            }
        }
    }

    /// Load the distinct year-months that have Monthly records, newest first
    private func loadAvailableMonths() {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "timeFrame == %@", TimeFrame.month.rawValue)

        do {
            let entries = try context.fetch(request)
            let calendar = Calendar.current
            let months = Set(entries.compactMap { entry -> MonthSelection? in
                guard let timestamp = entry.timestamp else { return nil }
                let components = calendar.dateComponents([.year, .month], from: timestamp)
                guard let year = components.year, let month = components.month else { return nil }
                return MonthSelection(year: year, month: month)
            })
            availableMonths = months.sorted { ($0.year, $0.month) > ($1.year, $1.month) }
        } catch {
            debugLog("Failed to load available months: \(error.localizedDescription)")
        }
    }

    private func loadAvailableYears() {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        do {
            let entries = try context.fetch(request)
            let years = Set(entries.compactMap { entry -> Int? in
                guard let timestamp = entry.timestamp else { return nil }
                return Calendar.current.component(.year, from: timestamp)
            })
            availableYears = years.sorted(by: >)  // Most recent first
        } catch {
            debugLog("Failed to load available years: \(error.localizedDescription)")
        }
    }

    /// Fetch the best records for a specific past month from Core Data history
    private func fetchRecordsForMonth(_ selection: MonthSelection) -> [RecordDetail] {
        let context = PersistenceController.shared.container.viewContext
        let calendar = Calendar.current

        guard let startOfMonth = selection.startDate,
              let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) else {
            return []
        }

        // Prepare home location filter if available
        let homeLocation: CLLocation? = settings.homeCoordinate.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }

        var monthRecords: [RecordDetail] = []

        for recordType in RecordType.allCases {
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@ AND timeFrame == %@",
                recordType.rawValue,
                startOfMonth as NSDate,
                endOfMonth as NSDate,
                TimeFrame.month.rawValue
            )

            do {
                var entries = try context.fetch(request)

                // Filter out records at home
                if let home = homeLocation {
                    entries = entries.filter { entry in
                        let entryLocation = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
                        return entryLocation.distance(from: home) > atHomeRadiusMeters
                    }
                }

                if let entry = recordType.displayRecord(of: entries, slotTimeFrame: .month),
                   var record = RecordDetail(from: entry) {
                    record.timeFrame = .month  // The slot it stands in, as loadRecordsFromHistory does
                    monthRecords.append(record)
                }
            } catch {
                debugLog("Failed to fetch record for \(recordType.rawValue) in \(selection.displayName): \(error.localizedDescription)")
            }
        }

        return monthRecords
    }

    /// Fetch the best records for a specific year from Core Data history
    private func fetchRecordsForYear(_ year: Int) -> [RecordDetail] {
        let context = PersistenceController.shared.container.viewContext
        let calendar = Calendar.current

        // Get the date range for this year
        guard let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let endOfYear = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return []
        }

        // Prepare home location filter if available
        let homeLocation: CLLocation? = settings.homeCoordinate.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }

        var yearRecords: [RecordDetail] = []

        // For each record type, find the best record from that year.
        // Include Monthly rows alongside Yearly ones so this matches the "This Year"
        // semantics in RecordManager.loadRecordsFromHistory (a January monthly record
        // is part of that year even if no separate Yearly row exists).
        for recordType in RecordType.allCases {
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@ AND timeFrame IN %@",
                recordType.rawValue,
                startOfYear as NSDate,
                endOfYear as NSDate,
                [TimeFrame.year.rawValue, TimeFrame.month.rawValue]
            )

            do {
                var entries = try context.fetch(request)

                // Filter out records at home
                if let home = homeLocation {
                    entries = entries.filter { entry in
                        let entryLocation = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
                        return entryLocation.distance(from: home) > atHomeRadiusMeters
                    }
                }

                // Same slot-selection rule as "This Year" (wizard choice, else extreme)
                if let entry = recordType.displayRecord(of: entries, slotTimeFrame: .year),
                   var record = RecordDetail(from: entry) {
                    record.timeFrame = .year  // The slot it stands in, as loadRecordsFromHistory does
                    yearRecords.append(record)
                }
            } catch {
                debugLog("Failed to fetch record for \(recordType.rawValue) in year \(year): \(error.localizedDescription)")
            }
        }

        return yearRecords
    }
}

// MARK: - Record Value Display

private struct RecordValueDisplay: View {
    let value: String
    let recordType: String
    let sizing: CardSizing
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: sizing.isCompact ? 2 : 4) {
            if !sizing.isCompact {
                Text("Value")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: sizing.valueFontSize, weight: .bold, design: .rounded))
                .foregroundColor(FormatUtils.colorForRecordType(recordType))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let caption {
                Text(caption)
                    .font(sizing.isCompact ? .caption2 : .caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

// MARK: - Record Photo Thumbnail

// MARK: - Record Card View

struct RecordCardView: View {
    let record: RecordDetail
    var context: RecordCardContext? = nil
    @EnvironmentObject var settings: SettingsManager

    @State private var caption: String?
    @Environment(\.cardSizing) private var sizing

    /// Within-reach on This Month cards, else progression, else nothing
    @MainActor
    private func loadCaption() {
        let unitSystem = settings.unitSystem
        if let context, context.isCurrentPeriod, context.slotTimeFrame == .month,
           let text = RecordCaption.withinReach(
                month: record,
                year: RecordManager.shared.getRecord(type: record.recordType, timeFrame: .year),
                lifetime: RecordManager.shared.getRecord(type: record.recordType, timeFrame: .allTime),
                unitSystem: unitSystem) {
            caption = text
            return
        }
        let previous = RecordHistoryManager.shared.previousRecord(before: record)
        caption = RecordCaption.progression(current: record, previous: previous, unitSystem: unitSystem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sizing.cardSpacing) {
            RecordCardHeader(
                recordType: record.recordType,
                timestamp: record.timestamp,
                sizing: sizing
            )

            if !sizing.isCompact {
                Divider()
            }

            // Main content with photo on the right
            HStack(alignment: .top, spacing: sizing.isCompact ? 8 : 16) {
                // Left side - record details
                VStack(alignment: .leading, spacing: sizing.contentSpacing) {
                    RecordValueDisplay(
                        value: record.formattedValue(unitSystem: settings.unitSystem),
                        recordType: record.recordType,
                        sizing: sizing,
                        caption: caption
                    )

                    // Location
                    if let locationName = record.locationName {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Location")
                                .font(sizing.isCompact ? .caption2 : .caption)
                                .foregroundColor(.secondary)
                            Text(locationName)
                                .font(sizing.isCompact ? .caption2 : .subheadline)
                                .lineLimit(sizing.isCompact ? 1 : 2)
                        }
                    }

                    // "312 mi north of home", or cardinal coordinates (only on full-size)
                    if !sizing.isCompact {
                        let framing = HomeFraming.text(for: record, home: settings.homeCoordinate, unitSystem: settings.unitSystem)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(framing.label)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(framing.value)
                                .font(framing.label == "Coordinates" ? .system(.caption, design: .monospaced) : .caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Right side - photo thumbnail
                if record.photoAssetIdentifier != nil || record.photoData != nil {
                    RecordPhotoThumbnail(
                        recordId: record.id,
                        photoAssetIdentifier: record.photoAssetIdentifier,
                        photoCloudIdentifier: record.photoCloudIdentifier,
                        photoData: record.photoData,
                        timestamp: record.timestamp,
                        coordinate: record.coordinate,
                        sizing: sizing
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(sizing.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: sizing.isCompact ? 16 : 20)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal, sizing.horizontalPadding)
        .task(id: "\(record.id)-\(record.value)-\(context?.slotTimeFrame.rawValue ?? "")") {
            loadCaption()
        }
    }
}
