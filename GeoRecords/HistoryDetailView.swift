import SwiftUI
import CoreLocation
import MapKit

struct HistoryDetailView: View {
    let entry: RecordHistoryEntry
    @EnvironmentObject var settings: SettingsManager

    private var recordDetail: RecordDetail {
        RecordDetail(
            id: entry.id ?? UUID(),
            value: entry.value,
            timestamp: entry.timestamp ?? Date(),
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? "Unknown",
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
