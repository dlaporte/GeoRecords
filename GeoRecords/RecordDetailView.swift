import SwiftUI
import CoreLocation
import MapKit

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
        // Update Core Data
        RecordHistoryManager.shared.updateRecordNotes(recordId: record.id, notes: notes)

        // Update in-memory record
        if var updatedRecord = recordManager.getRecord(type: record.recordType, timeFrame: record.timeFrame) {
            updatedRecord.notes = notes
            recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: updatedRecord)
        }
    }

    private func deleteRecord() {
        // Delete from Core Data history
        RecordHistoryManager.shared.deleteRecord(recordId: record.id)

        // Clear from RecordManager in-memory using the helper method
        recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: nil)

        // Reload records from history to get the next best record
        recordManager.loadRecordsFromHistory()

        dismiss()
    }
}
