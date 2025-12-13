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
    @EnvironmentObject var recordManager: RecordManager

    private var recordDetail: RecordDetail? {
        RecordDetail(from: entry)
    }

    var body: some View {
        if let record = recordDetail {
            DetailContentView(record: record, onSaveNotes: saveNotes)
        } else {
            Text("Unable to load record details")
                .foregroundColor(.secondary)
        }
    }

    private func saveNotes(_ notes: String?) {
        guard let entryId = entry.id,
              let record = recordDetail else { return }

        // Update Core Data
        RecordHistoryManager.shared.updateRecordNotes(recordId: entryId, notes: notes)

        // Update in-memory record if this is the current record for its timeframe
        if var currentRecord = recordManager.getRecord(type: record.recordType, timeFrame: record.timeFrame),
           currentRecord.id == entryId {
            currentRecord.notes = notes
            recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: currentRecord)
        }
    }
}

// MARK: - Single History Detail View (for direct navigation)

struct HistoryDetailView: View {
    let entry: RecordHistoryEntry
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager

    private var recordDetail: RecordDetail? {
        RecordDetail(from: entry)
    }

    var body: some View {
        Group {
            if let record = recordDetail {
                DetailContentView(record: record, onSaveNotes: saveNotes)
            } else {
                Text("Unable to load record details")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(entry.recordType ?? "Detail")
    }

    private func saveNotes(_ notes: String?) {
        guard let entryId = entry.id,
              let record = recordDetail else { return }

        // Update Core Data
        RecordHistoryManager.shared.updateRecordNotes(recordId: entryId, notes: notes)

        // Update in-memory record if this is the current record for its timeframe
        if var currentRecord = recordManager.getRecord(type: record.recordType, timeFrame: record.timeFrame),
           currentRecord.id == entryId {
            currentRecord.notes = notes
            recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: currentRecord)
        }
    }
}
