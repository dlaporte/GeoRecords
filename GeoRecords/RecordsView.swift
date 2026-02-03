import SwiftUI
import MapKit
import CoreData

// MARK: - Notifications

extension Notification.Name {
    static let navigateToiCloudSync = Notification.Name("navigateToiCloudSync")
    static let scrollToiCloudSync = Notification.Name("scrollToiCloudSync")
    static let showSetupWizard = Notification.Name("showSetupWizard")
    static let statisticsDidChange = Notification.Name("statisticsDidChange")
    static let recordsDidChange = Notification.Name("recordsDidChange")
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
    @State private var selectedTimeFrame: TimeFrame = .allTime
    @State private var selectedYear: Int?
    @State private var availableYears: [Int] = []
    @State private var refreshTrigger = UUID()  // Forces view to recompute

    // Computed property to get all non-nil records in order for the selected timeframe
    // Only includes geographic extreme records (N/S/E/W/Up/FromHome), not region records
    private var allRecords: [RecordDetail] {
        // Reference refreshTrigger to force recomputation when it changes
        _ = refreshTrigger

        // For Year mode with a specific year selected, fetch best records from that year
        if selectedTimeFrame == .year, let year = selectedYear {
            return fetchRecordsForYear(year).filter { record in
                RecordType.from(string: record.recordType)?.isGeographicExtreme ?? false
            }
        }

        // Otherwise show current timeframe records (only geographic extremes, not regions)
        return RecordType.allCases
            .filter { $0.isGeographicExtreme }
            .compactMap { type in
                recordManager.getRecord(type: type.rawValue, timeFrame: selectedTimeFrame)
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Timeframe picker below title
                TimeFramePickerWithBadges(
                    selectedTimeFrame: $selectedTimeFrame,
                    selectedYear: $selectedYear,
                    availableYears: availableYears,
                    timeFrameLabel: { timeFrame in
                        switch timeFrame {
                        case .daily: return "Daily"
                        case .allTime: return "Lifetime"
                        case .year:
                            if let year = selectedYear {
                                return String(format: "%d", year)
                            }
                            return "This Year"
                        case .month: return "This Month"
                        }
                    },
                    yearString: { year in
                        String(format: "%d", year)
                    }
                )
                .padding()

                if allRecords.isEmpty {
                    // Empty state - show different content if syncing
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
                } else {
                    // Map in upper portion
                    Map(position: $mapPosition) {
                        ForEach(allRecords, id: \.id) { record in
                            Marker(record.recordType, coordinate: record.coordinate)
                                .tint(FormatUtils.colorForRecordType(record.recordType))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Swipeable cards in lower portion
                    TabView(selection: $currentRecordIndex) {
                        ForEach(Array(allRecords.enumerated()), id: \.element.id) { index, record in
                            RecordCardView(record: record)
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
                        // Update map when swiping to new record
                        if let record = allRecords[safe: newIndex] {
                            withAnimation {
                                mapPosition = .centered(on: record.coordinate, latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Records")
            .toolbar {
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
            .onChange(of: selectedTimeFrame) { _, newValue in
                // Reset year selection when switching away from This Year
                if newValue != .year {
                    selectedYear = nil
                }

                // Clear badge for this timeframe since user is viewing it
                recordManager.clearBadge(for: newValue)

                // Update map when timeframe changes
                if let record = allRecords[safe: currentRecordIndex] {
                    withAnimation {
                        mapPosition = .centered(on: record.coordinate, latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
                    }
                }
            }
            .onChange(of: selectedYear) { _, _ in
                // Update map when year changes
                currentRecordIndex = 0
                if let record = allRecords.first {
                    withAnimation {
                        mapPosition = .centered(on: record.coordinate, latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToDetail) {
                RecordDetailPager(records: allRecords, initialIndex: selectedRecordIndex)
            }
            .onAppear {
                loadAvailableYears()
                handleDeepLink()
                // Clear badge for the currently selected timeframe
                recordManager.clearBadge(for: selectedTimeFrame)
                // Initialize map to first record
                if let firstRecord = allRecords.first {
                    mapPosition = .centered(on: firstRecord.coordinate, latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
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
                    // Force view to recompute allRecords
                    refreshTrigger = UUID()
                    // Update map position if we have records
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: briefPauseNanos)
                        if let firstRecord = allRecords.first {
                            withAnimation {
                                mapPosition = .centered(on: firstRecord.coordinate, latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleDeepLink() {
        // Handle timeframe deep link from widgets and notifications
        if let timeFrame = deepLinkManager.navigateToRecordsTimeFrame {
            switch timeFrame {
            case "monthly", "Monthly":  // Widget uses lowercase, TimeFrame.rawValue is "Monthly"
                selectedTimeFrame = .month
            case "yearly", "Yearly":    // Widget uses lowercase, TimeFrame.rawValue is "Yearly"
                selectedTimeFrame = .year
            case "allTime", "Lifetime": // Widget uses "allTime", TimeFrame.rawValue is "Lifetime"
                selectedTimeFrame = .allTime
            default:
                break
            }
            deepLinkManager.navigateToRecordsTimeFrame = nil
        }

        // Handle record type deep link from notifications
        guard let recordType = deepLinkManager.recordType else { return }

        // Deep links from notifications - find the record in allRecords
        if let index = allRecords.firstIndex(where: { $0.recordType == recordType }) {
            selectedRecordIndex = index
            navigateToDetail = true
            deepLinkManager.recordType = nil
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

    /// Format year as plain string without locale-specific formatting (no commas)
    private func yearString(_ year: Int) -> String {
        return String(format: "%d", year)
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

        // For each record type, find the Yearly record from that year
        // Only consider records with timeFrame == "Yearly" to respect wizard selections
        for recordType in RecordType.allCases {
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@ AND timeFrame == %@",
                recordType.rawValue,
                startOfYear as NSDate,
                endOfYear as NSDate,
                "Yearly"
            )

            // Sort to get the most extreme
            let ascending = !recordType.isAscending
            request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: ascending)]
            // Don't use fetchLimit - we need to filter out home records first

            do {
                var entries = try context.fetch(request)

                // Filter out records at home
                if let home = homeLocation {
                    entries = entries.filter { entry in
                        let entryLocation = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
                        return entryLocation.distance(from: home) > atHomeRadiusMeters
                    }
                }

                // Take the first (most extreme) after filtering
                if let entry = entries.first,
                   var record = RecordDetail(from: entry) {
                    record.timeFrame = .allTime  // Display as all-time records
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
        }
    }
}

// MARK: - Record Photo Thumbnail

// MARK: - Record Card View

struct RecordCardView: View {
    let record: RecordDetail
    @EnvironmentObject var settings: SettingsManager

    private let sizing = CardSizing()

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
                        sizing: sizing
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

                    // Coordinates (only on full-size)
                    if !sizing.isCompact {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Coordinates")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(FormatUtils.formatCoordinates(record.coordinate))
                                .font(.system(.caption, design: .monospaced))
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
    }
}

// MARK: - Custom TimeFrame Picker with Badges

private struct TimeFramePickerWithBadges: View {
    @Binding var selectedTimeFrame: TimeFrame
    @Binding var selectedYear: Int?
    let availableYears: [Int]
    let timeFrameLabel: (TimeFrame) -> String
    let yearString: (Int) -> String

    @EnvironmentObject var recordManager: RecordManager

    var body: some View {
        HStack(spacing: 0) {
            ForEach([TimeFrame.allTime, .year, .month], id: \.self) { timeFrame in
                TimeFrameSegment(
                    timeFrame: timeFrame,
                    isSelected: selectedTimeFrame == timeFrame,
                    label: timeFrameLabel(timeFrame),
                    badgeCount: badgeCount(for: timeFrame)
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTimeFrame = timeFrame
                    }
                }
            }
        }
        .background(Color(UIColor.systemGray5))
        .cornerRadius(8)
        .contextMenu {
            if selectedTimeFrame == .year && !availableYears.isEmpty {
                Button {
                    selectedYear = nil
                } label: {
                    Label("This Year", systemImage: selectedYear == nil ? "checkmark" : "calendar")
                }
                Divider()
                ForEach(availableYears, id: \.self) { year in
                    Button {
                        selectedYear = year
                    } label: {
                        Label(yearString(year), systemImage: selectedYear == year ? "checkmark" : "calendar")
                    }
                }
            }
        }
    }

    private func badgeCount(for timeFrame: TimeFrame) -> Int {
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
}

private struct TimeFrameSegment: View {
    let timeFrame: TimeFrame
    let isSelected: Bool
    let label: String
    let badgeCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? Color(UIColor.systemBackground) : Color.clear
                    )
                    .cornerRadius(6)
                    .padding(2)

                // Badge indicator
                if badgeCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: -4, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
