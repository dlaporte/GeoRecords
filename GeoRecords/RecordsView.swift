import SwiftUI
import MapKit

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
        [
            recordManager.getRecord(type: "Furthest North", timeFrame: selectedTimeFrame),
            recordManager.getRecord(type: "Furthest South", timeFrame: selectedTimeFrame),
            recordManager.getRecord(type: "Furthest East", timeFrame: selectedTimeFrame),
            recordManager.getRecord(type: "Furthest West", timeFrame: selectedTimeFrame),
            recordManager.getRecord(type: "Furthest Up", timeFrame: selectedTimeFrame),
            recordManager.getRecord(type: "Furthest Down", timeFrame: selectedTimeFrame),
            recordManager.getRecord(type: "Furthest from Home", timeFrame: selectedTimeFrame)
        ].compactMap { $0 }
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
                    // Map in upper half
                    Map(position: $mapPosition) {
                        if let currentRecord = allRecords[safe: currentRecordIndex] {
                            Marker(currentRecord.recordType, coordinate: currentRecord.coordinate)
                                .tint(colorForRecordType(currentRecord.recordType))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.5)

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
                    .frame(height: UIScreen.main.bounds.height * 0.5 - 100)
                    .onChange(of: currentRecordIndex) { _, newIndex in
                        // Update map when swiping to new record
                        if let record = allRecords[safe: newIndex] {
                            withAnimation {
                                mapPosition = .region(MKCoordinateRegion(
                                    center: record.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
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
                    .frame(width: 280)
                }
            }
            .onChange(of: selectedTimeFrame) { _, _ in
                // Update map when timeframe changes
                if let record = allRecords[safe: currentRecordIndex] {
                    withAnimation {
                        mapPosition = .region(MKCoordinateRegion(
                            center: record.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
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
                        span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
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

    private func colorForRecordType(_ type: String) -> Color {
        switch type {
        case "Furthest North": return .blue
        case "Furthest South": return .cyan
        case "Furthest East": return .orange
        case "Furthest West": return .purple
        case "Furthest Up": return .green
        case "Furthest Down": return .brown
        case "Furthest from Home": return .red
        default: return .gray
        }
    }
}

// MARK: - Record Card View
struct RecordCardView: View {
    let record: RecordDetail
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with icon and title only
            HStack(spacing: 12) {
                // Icon (always shown)
                Image(systemName: iconForRecordType(record.recordType))
                    .font(.title)
                    .foregroundColor(colorForRecordType(record.recordType))
                    .frame(width: 44, height: 44)
                    .background(colorForRecordType(record.recordType).opacity(0.1))
                    .cornerRadius(12)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.recordType)
                        .font(.headline)
                    Text(formatDate(record.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Divider()

            // Main content with photo on the right
            HStack(alignment: .top, spacing: 16) {
                // Left side - record details
                VStack(alignment: .leading, spacing: 12) {
                    // Value
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Value")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(record.formattedValue(unitSystem: settings.unitSystem))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(colorForRecordType(record.recordType))
                    }

                    // Location
                    if let locationName = record.locationName {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Location")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(locationName)
                                .font(.subheadline)
                        }
                    }

                    // Coordinates
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Coordinates")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.4f, %.4f", record.coordinate.latitude, record.coordinate.longitude))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                // Right side - photo thumbnail if available
                if let photoData = record.photoData,
                   let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            Spacer()

            // Tap to view detail hint
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
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private func iconForRecordType(_ type: String) -> String {
        return FormatUtils.iconForRecordType(type)
    }

    private func colorForRecordType(_ type: String) -> Color {
        return FormatUtils.colorForRecordType(type)
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
