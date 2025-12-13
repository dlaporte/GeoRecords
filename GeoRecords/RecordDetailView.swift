import SwiftUI
import CoreLocation
import MapKit

// MARK: - Shared Record Operations

/// Deletes a record from Core Data and clears it from in-memory storage
/// - Parameters:
///   - record: The record to delete
///   - recordManager: The record manager to update
@MainActor
private func deleteRecordFromStorage(_ record: RecordDetail, recordManager: RecordManager) {
    // Delete from Core Data history
    RecordHistoryManager.shared.deleteRecord(recordId: record.id)

    // Clear from RecordManager in-memory
    recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: nil)

    // Reload records from history to get the next best record
    recordManager.loadRecordsFromHistory()
}

/// Updates notes for a record in both Core Data and in-memory storage
/// - Parameters:
///   - record: The record to update
///   - notes: The new notes (or nil to clear)
///   - recordManager: The record manager to update
@MainActor
private func updateRecordNotes(for record: RecordDetail, notes: String?, recordManager: RecordManager) {
    // Update Core Data
    RecordHistoryManager.shared.updateRecordNotes(recordId: record.id, notes: notes)

    // Update in-memory record if it's the current one
    if var updatedRecord = recordManager.getRecord(type: record.recordType, timeFrame: record.timeFrame),
       updatedRecord.id == record.id {
        updatedRecord.notes = notes
        recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: updatedRecord)
    }
}

// MARK: - Record Detail Pager

struct RecordDetailPager: View {
    let records: [RecordDetail]
    let initialIndex: Int

    @State private var currentIndex: Int = 0
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @Environment(\.dismiss) var dismiss

    init(records: [RecordDetail], initialIndex: Int) {
        self.records = records
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
    }

    private var currentRecord: RecordDetail? {
        records[safe: currentIndex]
    }

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                RecordDetailContent(record: record, onDelete: {
                    deleteRecord(record)
                })
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(currentRecord?.recordType ?? "Detail")
                        .font(.headline)
                    Text("\(currentIndex + 1) of \(records.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    if let record = currentRecord {
                        deleteRecord(record)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func deleteRecord(_ record: RecordDetail) {
        deleteRecordFromStorage(record, recordManager: recordManager)
        dismiss()
    }
}

// MARK: - Record Detail Content

private struct RecordDetailContent: View {
    let record: RecordDetail
    let onDelete: () -> Void
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager

    @State private var showDeleteAlert = false

    var body: some View {
        DetailContentView(record: record, onSaveNotes: saveNotes)
            .alert("Delete Record?", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } message: {
                Text("Are you sure you want to delete this \(record.recordType) record? This action cannot be undone.")
            }
    }

    private func saveNotes(_ notes: String?) {
        updateRecordNotes(for: record, notes: notes, recordManager: recordManager)
    }
}

// MARK: - Single Record Detail View (for direct navigation/deep links)

struct RecordDetailView: View {
    let record: RecordDetail
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @Environment(\.dismiss) var dismiss

    @State private var showDeleteAlert = false

    var body: some View {
        DetailContentView(record: record, onSaveNotes: saveNotes)
            .navigationTitle(record.recordType)
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
                Text("Are you sure you want to delete this \(record.recordType) record? This action cannot be undone.")
            }
    }

    private func saveNotes(_ notes: String?) {
        updateRecordNotes(for: record, notes: notes, recordManager: recordManager)
    }

    private func deleteRecord() {
        deleteRecordFromStorage(record, recordManager: recordManager)
        dismiss()
    }
}
