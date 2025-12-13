import SwiftUI
import CoreLocation
import MapKit

// MARK: - History Detail Pager

struct HistoryDetailPager: View {
    let entries: [RecordHistoryEntry]
    let initialIndex: Int

    @State private var currentIndex: Int = 0
    @EnvironmentObject var settings: SettingsManager

    init(entries: [RecordHistoryEntry], initialIndex: Int) {
        self.entries = entries
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
    }

    private var currentEntry: RecordHistoryEntry {
        entries[currentIndex]
    }

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HistoryDetailContent(entry: entry)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(currentEntry.recordType ?? "Detail")
                        .font(.headline)
                    Text("\(currentIndex + 1) of \(entries.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var navigationTitle: String {
        currentEntry.recordType ?? "Detail"
    }
}

// MARK: - History Detail Content

private struct HistoryDetailContent: View {
    let entry: RecordHistoryEntry
    @EnvironmentObject var settings: SettingsManager

    private var recordDetail: RecordDetail {
        let timeFrame: TimeFrame
        if let tf = entry.timeFrame {
            timeFrame = TimeFrame(rawValue: tf) ?? .allTime
        } else {
            timeFrame = .allTime
        }

        return RecordDetail(
            id: entry.id ?? UUID(),
            value: entry.value,
            timestamp: entry.timestamp ?? Date(),
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? "Unknown",
            timeFrame: timeFrame,
            photoData: entry.photoData,
            notes: entry.notes
        )
    }

    var body: some View {
        DetailContentView(record: recordDetail, onSaveNotes: saveNotes)
    }

    private func saveNotes(_ notes: String?) {
        if let entryId = entry.id {
            RecordHistoryManager.shared.updateRecordNotes(recordId: entryId, notes: notes)
        }
    }
}

// MARK: - Single History Detail View (for direct navigation)

struct HistoryDetailView: View {
    let entry: RecordHistoryEntry
    @EnvironmentObject var settings: SettingsManager

    private var recordDetail: RecordDetail {
        let timeFrame: TimeFrame
        if let tf = entry.timeFrame {
            timeFrame = TimeFrame(rawValue: tf) ?? .allTime
        } else {
            timeFrame = .allTime
        }

        return RecordDetail(
            id: entry.id ?? UUID(),
            value: entry.value,
            timestamp: entry.timestamp ?? Date(),
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? "Unknown",
            timeFrame: timeFrame,
            photoData: entry.photoData,
            notes: entry.notes
        )
    }

    var body: some View {
        DetailContentView(record: recordDetail, onSaveNotes: saveNotes)
            .navigationTitle(entry.recordType ?? "Detail")
    }

    private func saveNotes(_ notes: String?) {
        // Update Core Data
        if let entryId = entry.id {
            RecordHistoryManager.shared.updateRecordNotes(recordId: entryId, notes: notes)
        }
    }
}
