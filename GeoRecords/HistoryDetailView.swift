import SwiftUI
import CoreLocation
import MapKit
import Photos

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

    /// Safe-subscripted like RecordDetailPager: the page index can outlive the
    /// entries array for a frame after a deletion
    private var currentEntry: RecordHistoryEntry? {
        entries[safe: currentIndex]
    }

    private var currentRecordDetail: RecordDetail? {
        currentEntry.flatMap { RecordDetail(from: $0) }
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
                    Text(navigationTitle)
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
            Text(RecordDeleteCopy.message(recordType: currentEntry?.recordType))
        }
    }

    private var navigationTitle: String {
        currentEntry?.recordType ?? "Detail"
    }

    private func deleteCurrentRecord() {
        if let record = currentRecordDetail {
            deleteRecordFromStorage(record, recordManager: recordManager)
        }
        dismiss()
    }
}

// MARK: - History Detail Content

struct HistoryDetailContent: View {
    let entry: RecordHistoryEntry
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager

    private var recordDetail: RecordDetail? {
        RecordDetail(from: entry)
    }

    var body: some View {
        if let record = recordDetail {
            DetailContentView(
                record: record,
                onSaveNotes: saveNotes,
                onSaveLocationName: saveLocationName,
                onSavePhoto: savePhoto
            )
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

    private func savePhoto(_ asset: PHAsset) {
        guard let record = recordDetail else { return }
        updateRecordPhoto(for: record, asset: asset, recordManager: recordManager)
    }
}

// MARK: - History Detail Pane (regular width)

/// The selected entry's detail in a split view's detail column, with previous and
/// next in the toolbar in place of the compact layout's swipe pager
struct HistoryDetailPane: View {
    let entries: [RecordHistoryEntry]
    @Binding var selectedID: UUID?
    let current: RecordHistoryEntry

    @State private var showDeleteAlert = false
    @EnvironmentObject var recordManager: RecordManager

    private var index: Int? {
        entries.firstIndex { $0.objectID == current.objectID }
    }

    var body: some View {
        HistoryDetailContent(entry: current)
            .navigationTitle(current.recordType ?? "Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(current.recordType ?? "Detail")
                            .font(.headline)
                        if let index {
                            Text("\(index + 1) of \(entries.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        step(-1)
                    } label: {
                        Label("Previous", systemImage: "chevron.up")
                    }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(index == nil || index == 0)
                    Button {
                        step(1)
                    } label: {
                        Label("Next", systemImage: "chevron.down")
                    }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(index == nil || index == entries.count - 1)
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
                    if let record = RecordDetail(from: current) {
                        deleteRecordFromStorage(record, recordManager: recordManager)
                    }
                }
            } message: {
                Text(RecordDeleteCopy.message(recordType: current.recordType))
            }
    }

    private func step(_ delta: Int) {
        guard let index, let next = entries[safe: index + delta] else { return }
        selectedID = next.id
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
                DetailContentView(
                    record: record,
                    onSaveNotes: saveNotes,
                    onSaveLocationName: saveLocationName,
                    onSavePhoto: savePhoto
                )
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
            Text(RecordDeleteCopy.message(recordType: entry.recordType))
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

    private func savePhoto(_ asset: PHAsset) {
        guard let record = recordDetail else { return }
        updateRecordPhoto(for: record, asset: asset, recordManager: recordManager)
    }

    private func deleteRecord() {
        if let record = recordDetail {
            deleteRecordFromStorage(record, recordManager: recordManager)
        }
        dismiss()
    }
}
