import SwiftUI
import CoreLocation
import MapKit

// MARK: - History Detail Pager

struct HistoryDetailPager: View {
    let entries: [RecordHistoryEntry]
    let initialIndex: Int

    @State private var currentIndex: Int = 0
    @State private var showDeleteAlert = false
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @Environment(\.dismiss) var dismiss

    init(entries: [RecordHistoryEntry], initialIndex: Int) {
        self.entries = entries
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
    }

    private var currentEntry: RecordHistoryEntry {
        entries[currentIndex]
    }

    private var currentRecordDetail: RecordDetail? {
        RecordDetail(from: currentEntry)
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
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .alert("Delete Record?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteCurrentRecord()
            }
        } message: {
            Text("Are you sure you want to delete this \(currentEntry.recordType ?? "record")? This action cannot be undone.")
        }
    }

    private var navigationTitle: String {
        currentEntry.recordType ?? "Detail"
    }

    private func deleteCurrentRecord() {
        if let record = currentRecordDetail {
            deleteRecordFromStorage(record, recordManager: recordManager)
        }
        dismiss()
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
            DetailContentView(record: record, onSaveNotes: saveNotes, onSaveLocationName: saveLocationName)
        } else {
            Text("Unable to load record details")
                .foregroundColor(.secondary)
        }
    }

    private func saveNotes(_ notes: String?) {
        guard let record = recordDetail else { return }
        updateRecordNotes(for: record, notes: notes, recordManager: recordManager)
    }

    private func saveLocationName(_ locationName: String?) {
        guard let record = recordDetail else { return }
        RecordHistoryManager.shared.updateLocationNameForCoordinates(
            latitude: record.coordinate.latitude,
            longitude: record.coordinate.longitude,
            locationName: locationName
        )
    }
}

// MARK: - Single History Detail View (for direct navigation)

struct HistoryDetailView: View {
    let entry: RecordHistoryEntry
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @Environment(\.dismiss) var dismiss

    @State private var showDeleteAlert = false

    private var recordDetail: RecordDetail? {
        RecordDetail(from: entry)
    }

    var body: some View {
        Group {
            if let record = recordDetail {
                DetailContentView(record: record, onSaveNotes: saveNotes, onSaveLocationName: saveLocationName)
            } else {
                Text("Unable to load record details")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(entry.recordType ?? "Detail")
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .alert("Delete Record?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteRecord()
            }
        } message: {
            Text("Are you sure you want to delete this \(entry.recordType ?? "record")? This action cannot be undone.")
        }
    }

    private func saveNotes(_ notes: String?) {
        guard let record = recordDetail else { return }
        updateRecordNotes(for: record, notes: notes, recordManager: recordManager)
    }

    private func saveLocationName(_ locationName: String?) {
        guard let record = recordDetail else { return }
        RecordHistoryManager.shared.updateLocationNameForCoordinates(
            latitude: record.coordinate.latitude,
            longitude: record.coordinate.longitude,
            locationName: locationName
        )
    }

    private func deleteRecord() {
        if let record = recordDetail {
            deleteRecordFromStorage(record, recordManager: recordManager)
        }
        dismiss()
    }
}
