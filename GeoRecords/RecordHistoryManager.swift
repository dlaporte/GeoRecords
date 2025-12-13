import CoreData
import SwiftUI

@MainActor
class RecordHistoryManager: ObservableObject {
    static let shared = RecordHistoryManager()

    @Published var errorMessage: String?
    @Published var showError: Bool = false

    private var context: NSManagedObjectContext {
        dispatchPrecondition(condition: .onQueue(.main))
        return PersistenceController.shared.container.viewContext
    }

    func addRecord(recordType: String, detail: RecordDetail) {
        // Check if this record already exists to prevent duplicates
        if recordExists(recordType: recordType, detail: detail) {
            debugLog("⚠️ Duplicate record detected and skipped: \(recordType) (\(detail.timeFrame.rawValue)) at \(detail.timestamp)")
            return
        }

        let newEntry = RecordHistoryEntry(context: context)
        newEntry.id = detail.id
        newEntry.timestamp = detail.timestamp  // timestamp is non-optional Date
        newEntry.recordType = recordType
        newEntry.timeFrame = detail.timeFrame.rawValue
        newEntry.value = detail.value
        newEntry.latitude = detail.coordinate.latitude
        newEntry.longitude = detail.coordinate.longitude
        newEntry.altitude = detail.altitude
        newEntry.locationName = detail.locationName
        newEntry.photoData = detail.photoData
        newEntry.notes = detail.notes

        do {
            try context.save()
            debugLog("Record saved: \(recordType) (\(detail.timeFrame.rawValue)) with value: \(detail.value)")
        } catch {
            let message = "Failed to save record: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Check if a record already exists (prevents duplicates from imports/syncs)
    private func recordExists(recordType: String, detail: RecordDetail) -> Bool {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        // Define tolerance for coordinate comparison (about 1 meter)
        let coordinateTolerance = 0.00001
        let valueTolerance = 0.0001
        let timeTolerance: TimeInterval = 1.0 // 1 second

        // Calculate date range for comparison
        let timestampMin = detail.timestamp.addingTimeInterval(-timeTolerance)
        let timestampMax = detail.timestamp.addingTimeInterval(timeTolerance)
        let valueMin = detail.value - valueTolerance
        let valueMax = detail.value + valueTolerance
        let latMin = detail.coordinate.latitude - coordinateTolerance
        let latMax = detail.coordinate.latitude + coordinateTolerance
        let lonMin = detail.coordinate.longitude - coordinateTolerance
        let lonMax = detail.coordinate.longitude + coordinateTolerance

        // Match records with same type, timeframe, timestamp (within 1 second), and similar coordinates
        request.predicate = NSPredicate(
            format: "recordType == %@ AND timeFrame == %@ AND timestamp >= %@ AND timestamp <= %@ AND value >= %f AND value <= %f AND latitude >= %f AND latitude <= %f AND longitude >= %f AND longitude <= %f",
            recordType,
            detail.timeFrame.rawValue,
            timestampMin as NSDate,
            timestampMax as NSDate,
            valueMin,
            valueMax,
            latMin,
            latMax,
            lonMin,
            lonMax
        )
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            return !results.isEmpty
        } catch {
            debugLog("❌ Database error checking for duplicate record: \(error.localizedDescription)")
            debugLog("   Record type: \(recordType), timestamp: \(detail.timestamp)")
            // If check fails, allow the record to be added rather than silently dropping it
            return false
        }
    }

    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }

    func updateRecordPhoto(recordId: UUID, photoData: Data?) {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", recordId as CVarArg)
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let entry = results.first {
                entry.photoData = photoData
                try context.save()
                debugLog("Photo updated for record \(recordId)")
            }
        } catch {
            let message = "Failed to update photo: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    func updateRecordNotes(recordId: UUID, notes: String?) {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", recordId as CVarArg)
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let entry = results.first {
                entry.notes = notes
                try context.save()
                debugLog("Notes updated for record \(recordId)")
            }
        } catch {
            let message = "Failed to update notes: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    func deleteRecord(recordId: UUID) {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", recordId as CVarArg)
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let entry = results.first {
                let recordType = entry.recordType ?? "Unknown"
                context.delete(entry)
                try context.save()
                debugLog("Deleted record: \(recordType) with id: \(recordId)")
            } else {
                debugLog("Record not found for deletion: \(recordId)")
            }
        } catch {
            let message = "Failed to delete record: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Consolidate records by keeping only the most extreme record for each recordType+timeFrame+period combination
    /// For Monthly records: keeps one per calendar month
    /// For Yearly records: keeps one per calendar year
    /// For All-Time records: keeps only the single most extreme
    /// Deletes all non-extreme records from history (both locally and iCloud)
    /// Returns the number of records removed
    @discardableResult
    func consolidateRecords() -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        let calendar = Calendar.current

        do {
            let allRecords = try context.fetch(request)
            var recordsRemoved = 0

            // Group records by recordType + timeFrame + actual time period
            var recordGroups: [String: [RecordHistoryEntry]] = [:]

            for record in allRecords {
                guard let recordType = record.recordType,
                      let timeFrameStr = record.timeFrame,
                      let timestamp = record.timestamp else {
                    continue
                }

                // Build grouping key based on timeframe type
                let periodKey: String
                switch timeFrameStr {
                case "Monthly":
                    // Group by year-month (keeps historical monthly records separate)
                    let year = calendar.component(.year, from: timestamp)
                    let month = calendar.component(.month, from: timestamp)
                    periodKey = "\(year)-\(String(format: "%02d", month))"
                case "Yearly":
                    // Group by year only (keeps historical yearly records separate)
                    let year = calendar.component(.year, from: timestamp)
                    periodKey = "\(year)"
                case "All-Time":
                    // Single group for all time
                    periodKey = "all"
                default:
                    periodKey = "unknown"
                }

                let key = "\(recordType)|\(timeFrameStr)|\(periodKey)"
                if recordGroups[key] == nil {
                    recordGroups[key] = []
                }
                recordGroups[key]?.append(record)
            }

            // For each group, keep only the most extreme record
            for (key, records) in recordGroups {
                guard records.count > 1 else { continue } // Skip if only one record

                let components = key.split(separator: "|")
                guard components.count >= 2,
                      let recordType = RecordType.from(string: String(components[0])) else {
                    continue
                }

                // Sort by value to find the most extreme
                let sortedRecords = records.sorted { record1, record2 in
                    recordType.shouldReplace(newValue: record1.value, oldValue: record2.value)
                }

                // Keep the first (most extreme), delete the rest
                let toKeep = sortedRecords.first
                for record in sortedRecords {
                    if record.objectID != toKeep?.objectID {
                        context.delete(record)
                        recordsRemoved += 1
                        debugLog("🗑️ Consolidating: Removed \(record.recordType ?? "Unknown") (\(record.timeFrame ?? "Unknown")) with value \(record.value)")
                    }
                }
            }

            if recordsRemoved > 0 {
                try context.save()
                debugLog("✅ Consolidated records: removed \(recordsRemoved) non-extreme record(s)")

                // Reload in-memory records to reflect changes
                RecordManager.shared.loadRecordsFromHistory()
            } else {
                debugLog("✅ No records to consolidate - all records are already extreme values")
            }

            return recordsRemoved
        } catch {
            debugLog("❌ Error consolidating records: \(error.localizedDescription)")
            return 0
        }
    }

    /// Clear all records from history (both locally and iCloud)
    /// Uses individual deletes instead of batch delete to ensure proper CloudKit sync
    func clearHistory() {
        let fetchRequest: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        do {
            let allRecords = try context.fetch(fetchRequest)
            let recordCount = allRecords.count

            // Delete each record individually to ensure CloudKit tracks the deletions
            for record in allRecords {
                context.delete(record)
            }

            try context.save()
            debugLog("✅ Deleted \(recordCount) records (will sync deletion to iCloud)")

            // Also reset in-memory records so that Records screen updates.
            RecordManager.shared.resetRecords()

            // Clear daily statistics as well
            DailyStatisticManager.shared.clearAllStatistics()
        } catch {
            let message = "Failed to clear records: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Clear local records only - iCloud data remains and will sync back
    /// This deletes the local SQLite file directly to avoid CloudKit sync
    func clearLocalOnly() {
        // Reset in-memory records first
        RecordManager.shared.resetRecords()

        // Get the store URL
        guard let storeDescription = PersistenceController.shared.container.persistentStoreDescriptions.first,
              let storeURL = storeDescription.url else {
            debugLog("⚠️ Could not find store URL for local clear")
            return
        }

        // Remove the persistent store
        let coordinator = PersistenceController.shared.container.persistentStoreCoordinator
        if let store = coordinator.persistentStore(for: storeURL) {
            do {
                try coordinator.remove(store)

                // Delete the SQLite files
                let fileManager = FileManager.default
                let storePath = storeURL.path
                for suffix in ["", "-shm", "-wal"] {
                    let filePath = storePath + suffix
                    if fileManager.fileExists(atPath: filePath) {
                        try fileManager.removeItem(atPath: filePath)
                    }
                }

                debugLog("✅ Local database cleared (iCloud data preserved)")

                // Reload the store - iCloud will sync data back
                PersistenceController.shared.container.loadPersistentStores { _, error in
                    if let error = error {
                        debugLog("❌ Failed to reload store: \(error.localizedDescription)")
                    } else {
                        debugLog("✅ Store reloaded - iCloud sync will restore data")
                    }
                }
            } catch {
                debugLog("❌ Failed to clear local database: \(error.localizedDescription)")
            }
        }
    }

    /// Remove duplicate records from history
    /// Duplicates are defined as records with exact matches on:
    /// recordType, timeFrame, timestamp, value, latitude, longitude
    /// Returns the number of duplicates removed
    @discardableResult
    func removeDuplicates() -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            let allRecords = try context.fetch(request)
            var duplicatesRemoved = 0
            var seenRecords: [String: RecordHistoryEntry] = [:]

            for record in allRecords {
                // Create a unique key from all the fields that define a duplicate
                guard let recordType = record.recordType,
                      let timeFrame = record.timeFrame,
                      let timestamp = record.timestamp else {
                    continue
                }

                // Use exact values for key - no tolerance
                let key = "\(recordType)|\(timeFrame)|\(timestamp.timeIntervalSince1970)|\(record.value)|\(record.latitude)|\(record.longitude)"

                if seenRecords[key] != nil {
                    // This is a duplicate - delete it
                    context.delete(record)
                    duplicatesRemoved += 1
                    debugLog("🗑️ Removing duplicate: \(recordType) (\(timeFrame)) at \(timestamp)")
                } else {
                    // First time seeing this record - keep it
                    seenRecords[key] = record
                }
            }

            if duplicatesRemoved > 0 {
                try context.save()
                debugLog("✅ Removed \(duplicatesRemoved) duplicate record(s) from history")
            } else {
                debugLog("✅ No duplicate records found")
            }

            return duplicatesRemoved
        } catch {
            debugLog("❌ Error removing duplicates: \(error.localizedDescription)")
            return 0
        }
    }
}
