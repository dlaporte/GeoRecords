import SwiftUI
import CoreLocation
import MapKit
import Photos

// MARK: - Shared Record Operations

/// Deletes a record and all related records (same photo/timestamp) from Core Data
/// Also updates daily statistics for the affected day
/// - Parameters:
///   - record: The record to delete
///   - recordManager: The record manager to update
@MainActor
func deleteRecordFromStorage(_ record: RecordDetail, recordManager: RecordManager) {
    // Delete cached thumbnail
    ThumbnailCache.shared.deleteThumbnail(for: record.id)

    // Delete this record and all related records with the same timestamp
    // (Records from the same photo have the same timestamp)
    let deletedCount = RecordHistoryManager.shared.deleteRelatedRecords(
        recordType: record.recordType,
        timestamp: record.timestamp,
        coordinate: record.coordinate
    )

    if deletedCount > 1 {
        debugLog("🗑️ Deleted \(deletedCount) related records (same photo)")
    }

    // Clear from RecordManager in-memory for all timeframes
    for timeFrame in TimeFrame.userVisibleCases {
        if let existing = recordManager.getRecord(type: record.recordType, timeFrame: timeFrame),
           existing.timestamp == record.timestamp {
            recordManager.setRecord(type: record.recordType, timeFrame: timeFrame, record: nil)
        }
    }

    // Reload records from history to get the next best record
    recordManager.loadRecordsFromHistory()
}

/// Updates notes for a record in both Core Data and in-memory storage
/// - Parameters:
///   - record: The record to update
///   - notes: The new notes (or nil to clear)
///   - recordManager: The record manager to update
@MainActor
func updateRecordNotes(for record: RecordDetail, notes: String?, recordManager: RecordManager) {
    // Update Core Data
    RecordHistoryManager.shared.updateRecordNotes(recordId: record.id, notes: notes)

    // Update in-memory record if it's the current one
    if var updatedRecord = recordManager.getRecord(type: record.recordType, timeFrame: record.timeFrame),
       updatedRecord.id == record.id {
        updatedRecord.notes = notes
        recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: updatedRecord)
    }
}

/// Updates the photo for a record in both Core Data and in-memory storage
/// - Parameters:
///   - record: The record to update
///   - asset: The new photo asset
///   - recordManager: The record manager to update
@MainActor
func updateRecordPhoto(for record: RecordDetail, asset: PHAsset, recordManager: RecordManager) {
    let localId = asset.localIdentifier

    // Get cloud identifier for cross-device sync
    let cloudId = PHPhotoLibrary.cloudIdentifier(for: asset)

    // Update Core Data
    RecordHistoryManager.shared.updateRecordPhotoAsset(
        recordId: record.id,
        localIdentifier: localId,
        cloudIdentifier: cloudId
    )

    // Clear cached thumbnail so it reloads with new photo
    ThumbnailCache.shared.deleteThumbnail(for: record.id)

    // Check if this is a region record
    let recordType = RecordType.from(string: record.recordType)
    let isRegion = recordType?.isRegionVisit ?? false

    if isRegion {
        // For region records, reload visited regions from Core Data
        RegionTrackingManager.shared.loadVisitedRegions()
        debugLog("📸 Changed photo for region \(record.recordType) to asset \(localId)")
    } else {
        // For geographic records, update in-memory and reload
        if var updatedRecord = recordManager.getRecord(type: record.recordType, timeFrame: record.timeFrame),
           updatedRecord.id == record.id {
            updatedRecord.photoAssetIdentifier = localId
            updatedRecord.photoCloudIdentifier = cloudId
            updatedRecord.photoData = nil  // Clear legacy data
            recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: updatedRecord)
        }

        // Reload all records from history to ensure consistency
        recordManager.loadRecordsFromHistory()
        debugLog("📸 Changed photo for \(record.recordType) to asset \(localId)")
    }
}

// MARK: - Record Detail Pager

struct RecordDetailPager: View {
    let records: [RecordDetail]
    let initialIndex: Int

    @State private var currentIndex: Int = 0
    @State private var showDeleteAlert = false
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
                    showDeleteAlert = true
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
                    showDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .alert("Delete Record?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let record = currentRecord {
                    deleteRecord(record)
                }
            }
        } message: {
            Text("Are you sure you want to delete this \(currentRecord?.recordType ?? "record")? This action cannot be undone.")
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
        DetailContentView(
            record: record,
            onSaveNotes: saveNotes,
            onSaveLocationName: saveLocationName,
            onSavePhoto: savePhoto
        )
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

    private func saveLocationName(_ locationName: String?) {
        // Update all records at the same coordinates
        RecordHistoryManager.shared.updateLocationNameForCoordinates(
            latitude: record.coordinate.latitude,
            longitude: record.coordinate.longitude,
            locationName: locationName
        )
    }

    private func savePhoto(_ asset: PHAsset) {
        updateRecordPhoto(for: record, asset: asset, recordManager: recordManager)
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
        DetailContentView(
            record: record,
            onSaveNotes: saveNotes,
            onSaveLocationName: saveLocationName,
            onSavePhoto: savePhoto
        )
        .navigationTitle(record.locationName ?? record.recordType)
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

    private func saveLocationName(_ locationName: String?) {
        RecordHistoryManager.shared.updateLocationNameForCoordinates(
            latitude: record.coordinate.latitude,
            longitude: record.coordinate.longitude,
            locationName: locationName
        )
    }

    private func savePhoto(_ asset: PHAsset) {
        updateRecordPhoto(for: record, asset: asset, recordManager: recordManager)
    }

    private func deleteRecord() {
        deleteRecordFromStorage(record, recordManager: recordManager)
        dismiss()
    }
}
