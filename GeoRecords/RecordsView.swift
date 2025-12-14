import SwiftUI
import MapKit
import CoreData

// MARK: - Layout Constants

private let mapHeightRatio: CGFloat = 0.5
private let cardHeightOffset: CGFloat = 100
private let pickerWidth: CGFloat = 280

struct RecordsView: View {
    @EnvironmentObject var recordManager: RecordManager
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var deepLinkManager: DeepLinkManager

    @State private var navigateToDetail = false
    @State private var selectedRecordIndex: Int = 0
    @State private var currentRecordIndex = 0
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedTimeFrame: TimeFrame = .allTime
    @State private var selectedYear: Int?
    @State private var availableYears: [Int] = []

    // Computed property to get all non-nil records in order for the selected timeframe
    private var allRecords: [RecordDetail] {
        // For All Time mode with a specific year selected, fetch best records from that year
        if selectedTimeFrame == .allTime, let year = selectedYear {
            return fetchRecordsForYear(year)
        }

        // Otherwise show current timeframe records
        return RecordType.allCases.compactMap { type in
            recordManager.getRecord(type: type.rawValue, timeFrame: selectedTimeFrame)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if allRecords.isEmpty {
                    // Empty state
                    VStack(spacing: 20) {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Map in upper half showing all records
                    Map(position: $mapPosition) {
                        ForEach(allRecords, id: \.id) { record in
                            Marker(record.recordType, coordinate: record.coordinate)
                                .tint(FormatUtils.colorForRecordType(record.recordType))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * mapHeightRatio)

                    // Swipeable cards in lower half
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
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * mapHeightRatio - cardHeightOffset)
                    .onChange(of: currentRecordIndex) { _, newIndex in
                        // Update map when swiping to new record
                        if let record = allRecords[safe: newIndex] {
                            withAnimation {
                                mapPosition = .region(MKCoordinateRegion(
                                    center: record.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
                                ))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Records")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Time Frame", selection: $selectedTimeFrame) {
                        ForEach(TimeFrame.allCases, id: \.self) { timeFrame in
                            Text(timeFrameLabel(for: timeFrame)).tag(timeFrame)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: pickerWidth)
                    .contextMenu {
                        if selectedTimeFrame == .allTime && !availableYears.isEmpty {
                            Button {
                                selectedYear = nil
                            } label: {
                                Label("All Years", systemImage: selectedYear == nil ? "checkmark" : "calendar")
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
            }
            .onChange(of: selectedTimeFrame) { _, newValue in
                // Reset year selection when switching away from All Time
                if newValue != .allTime {
                    selectedYear = nil
                }

                // Update map when timeframe changes
                if let record = allRecords[safe: currentRecordIndex] {
                    withAnimation {
                        mapPosition = .region(MKCoordinateRegion(
                            center: record.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
                        ))
                    }
                }
            }
            .onChange(of: selectedYear) { _, _ in
                // Update map when year changes
                currentRecordIndex = 0
                if let record = allRecords.first {
                    withAnimation {
                        mapPosition = .region(MKCoordinateRegion(
                            center: record.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
                        ))
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToDetail) {
                RecordDetailPager(records: allRecords, initialIndex: selectedRecordIndex)
            }
            .onAppear {
                loadAvailableYears()
                handleDeepLink()
                // Initialize map to first record
                if let firstRecord = allRecords.first {
                    mapPosition = .region(MKCoordinateRegion(
                        center: firstRecord.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: wideMapLatDelta, longitudeDelta: wideMapLonDelta)
                    ))
                }
            }
            .onChange(of: deepLinkManager.recordType) { _, _ in
                handleDeepLink()
            }
        }
    }

    private func handleDeepLink() {
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

    /// Get label for timeframe, showing selected year if applicable
    private func timeFrameLabel(for timeFrame: TimeFrame) -> String {
        if timeFrame == .allTime, let year = selectedYear {
            return yearString(year)
        }
        return timeFrame.displayName
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

        var yearRecords: [RecordDetail] = []

        // For each record type, find the most extreme record from that year
        for recordType in RecordType.allCases {
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@",
                recordType.rawValue,
                startOfYear as NSDate,
                endOfYear as NSDate
            )

            // Sort to get the most extreme
            let ascending = !recordType.isAscending
            request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: ascending)]
            request.fetchLimit = 1

            do {
                if let entry = try context.fetch(request).first,
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

// MARK: - Record Card Sizing

/// Encapsulates responsive sizing values for record cards
private struct CardSizing {
    let isCompact: Bool

    init() {
        let screenHeight = UIScreen.main.bounds.height
        isCompact = screenHeight < compactScreenHeightThreshold
    }

    var cardSpacing: CGFloat { isCompact ? 8 : 12 }
    var iconSize: CGFloat { isCompact ? 32 : 44 }
    var valueFontSize: CGFloat { isCompact ? 24 : 36 }
    var photoSize: CGFloat { isCompact ? 80 : 120 }
    var cardPadding: CGFloat { isCompact ? 12 : 16 }
    var horizontalPadding: CGFloat { isCompact ? 10 : 16 }
    var contentSpacing: CGFloat { isCompact ? 6 : 12 }
}

// MARK: - Record Card Header

private struct RecordCardHeader: View {
    let recordType: String
    let timestamp: Date
    let sizing: CardSizing

    var body: some View {
        HStack(spacing: sizing.isCompact ? 8 : 12) {
            Image(systemName: FormatUtils.iconForRecordType(recordType))
                .font(sizing.isCompact ? .title3 : .title)
                .foregroundColor(FormatUtils.colorForRecordType(recordType))
                .frame(width: sizing.iconSize, height: sizing.iconSize)
                .background(FormatUtils.colorForRecordType(recordType).opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(recordType)
                    .font(sizing.isCompact ? .caption : .headline)
                    .fontWeight(.semibold)
                Text(mediumDateFormatter.string(from: timestamp))
                    .font(sizing.isCompact ? .caption2 : .caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
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

private struct RecordPhotoThumbnail: View {
    let photoAssetIdentifier: String?
    let photoCloudIdentifier: String?
    let photoData: Data?  // Legacy fallback
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    let sizing: CardSizing

    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: sizing.photoSize, height: sizing.photoSize)
                    .clipShape(RoundedRectangle(cornerRadius: sizing.isCompact ? 8 : 12))
            } else {
                RoundedRectangle(cornerRadius: sizing.isCompact ? 8 : 12)
                    .fill(Color(UIColor.tertiarySystemGroupedBackground))
                    .frame(width: sizing.photoSize, height: sizing.photoSize)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.7)
                    )
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // Try to load from Photos library with fallback: local ID → cloud ID → timestamp/location
        if let identifier = photoAssetIdentifier {
            if let photo = await PhotoReferenceManager.shared.fetchThumbnailWithFallback(
                identifier: identifier,
                cloudIdentifier: photoCloudIdentifier,
                timestamp: timestamp,
                coordinate: coordinate
            ) {
                loadedImage = photo
                return
            }
        }

        // Fallback to legacy embedded photo data
        if let data = photoData, let image = UIImage(data: data) {
            loadedImage = image
        }
    }
}

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
                            Text(String(format: "%.4f, %.4f", record.coordinate.latitude, record.coordinate.longitude))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Right side - photo thumbnail
                if record.photoAssetIdentifier != nil || record.photoData != nil {
                    RecordPhotoThumbnail(
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

            // Tap to view detail hint
            if !sizing.isCompact {
                HStack {
                    Spacer()
                    Text("Tap for details")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
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
