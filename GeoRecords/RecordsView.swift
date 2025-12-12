import SwiftUI
import MapKit

// MARK: - Layout Constants

private let mapHeightRatio: CGFloat = 0.5
private let cardHeightOffset: CGFloat = 100
private let pickerWidth: CGFloat = 280

struct RecordsView: View {
    @EnvironmentObject var recordManager: RecordManager
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var deepLinkManager: DeepLinkManager

    @State private var navigateToDetail = false
    @State private var selectedRecord: RecordDetail?
    @State private var currentRecordIndex = 0
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedTimeFrame: TimeFrame = .allTime

    // Computed property to get all non-nil records in order for the selected timeframe
    private var allRecords: [RecordDetail] {
        RecordType.allCases.compactMap { type in
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
                                    selectedRecord = record
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
                            Text(timeFrame.rawValue).tag(timeFrame)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: pickerWidth)
                }
            }
            .onChange(of: selectedTimeFrame) { _, _ in
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
            .navigationDestination(isPresented: $navigateToDetail) {
                if let record = selectedRecord {
                    RecordDetailView(record: record)
                }
            }
            .onAppear {
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

        if let record = recordForType(recordType) {
            selectedRecord = record
            navigateToDetail = true
            deepLinkManager.recordType = nil
        }
    }

    func recordForType(_ type: String) -> RecordDetail? {
        // Deep links from notifications always go to all-time records
        return recordManager.getRecord(type: type, timeFrame: .allTime)
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
    let photoData: Data
    let sizing: CardSizing

    var body: some View {
        if let uiImage = UIImage(data: photoData) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: sizing.photoSize, height: sizing.photoSize)
                .clipShape(RoundedRectangle(cornerRadius: sizing.isCompact ? 8 : 12))
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
                if let photoData = record.photoData {
                    RecordPhotoThumbnail(photoData: photoData, sizing: sizing)
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
