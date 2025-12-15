import CoreData
import CoreLocation
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
        newEntry.dateAdded = Date()  // Track when record was imported
        newEntry.recordType = recordType
        newEntry.timeFrame = detail.timeFrame.rawValue
        newEntry.value = detail.value
        newEntry.latitude = detail.coordinate.latitude
        newEntry.longitude = detail.coordinate.longitude
        newEntry.altitude = detail.altitude
        newEntry.locationName = detail.locationName
        newEntry.photoData = detail.photoData
        newEntry.photoAssetIdentifier = detail.photoAssetIdentifier
        newEntry.photoCloudIdentifier = detail.photoCloudIdentifier
        newEntry.notes = detail.notes

        if let photoId = detail.photoAssetIdentifier {
            debugLog("💾 Saving record with photo: \(photoId)")
            if let cloudId = detail.photoCloudIdentifier {
                debugLog("☁️ Cloud identifier: \(cloudId)")
            }
        } else {
            debugLog("⚠️ Saving record WITHOUT photo attachment")
        }

        do {
            try context.save()
        } catch {
            let message = "Failed to save record: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Check if a record already exists (prevents duplicates from imports/syncs)
    private func recordExists(recordType: String, detail: RecordDetail) -> Bool {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        // Calculate date range for comparison using shared tolerance constants
        let timestampMin = detail.timestamp.addingTimeInterval(-duplicateTimeTolerance)
        let timestampMax = detail.timestamp.addingTimeInterval(duplicateTimeTolerance)
        let valueMin = detail.value - duplicateValueTolerance
        let valueMax = detail.value + duplicateValueTolerance
        let latMin = detail.coordinate.latitude - duplicateCoordinateTolerance
        let latMax = detail.coordinate.latitude + duplicateCoordinateTolerance
        let lonMin = detail.coordinate.longitude - duplicateCoordinateTolerance
        let lonMax = detail.coordinate.longitude + duplicateCoordinateTolerance

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
            }
        } catch {
            let message = "Failed to update notes: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Update the location name for a specific record
    func updateRecordLocationName(recordId: UUID, locationName: String?) {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", recordId as CVarArg)
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let entry = results.first {
                entry.locationName = locationName
                try context.save()
            }
        } catch {
            let message = "Failed to update location name: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Look up an existing location name for nearby coordinates
    /// Checks if any existing record has a location name within the tolerance distance
    /// - Parameters:
    ///   - latitude: The latitude to search near
    ///   - longitude: The longitude to search near
    /// - Returns: The location name if found, nil otherwise
    func lookupLocationName(latitude: Double, longitude: Double) -> String? {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        let latMin = latitude - locationNameCoordinateTolerance
        let latMax = latitude + locationNameCoordinateTolerance
        let lonMin = longitude - locationNameCoordinateTolerance
        let lonMax = longitude + locationNameCoordinateTolerance

        // Only fetch records that have a location name
        request.predicate = NSPredicate(
            format: "latitude >= %f AND latitude <= %f AND longitude >= %f AND longitude <= %f AND locationName != nil AND locationName != %@",
            latMin, latMax, lonMin, lonMax, ""
        )
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let existingName = results.first?.locationName {
                debugLog("📍 Found existing location name: \(existingName)")
                return existingName
            }
        } catch {
            debugLog("❌ Failed to lookup location name: \(error.localizedDescription)")
        }

        return nil
    }

    /// Update location name for all records at the same coordinates
    /// This ensures records at the same location (e.g., yearly and all-time) share the same name
    /// - Parameters:
    ///   - latitude: The latitude to match
    ///   - longitude: The longitude to match
    ///   - locationName: The new location name
    /// - Returns: Number of records updated
    @discardableResult
    func updateLocationNameForCoordinates(latitude: Double, longitude: Double, locationName: String?) -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        let latMin = latitude - locationNameCoordinateTolerance
        let latMax = latitude + locationNameCoordinateTolerance
        let lonMin = longitude - locationNameCoordinateTolerance
        let lonMax = longitude + locationNameCoordinateTolerance

        request.predicate = NSPredicate(
            format: "latitude >= %f AND latitude <= %f AND longitude >= %f AND longitude <= %f",
            latMin, latMax, lonMin, lonMax
        )

        do {
            let results = try context.fetch(request)
            var updatedCount = 0

            for entry in results {
                entry.locationName = locationName
                updatedCount += 1
            }

            if updatedCount > 0 {
                try context.save()
                debugLog("📍 Updated location name for \(updatedCount) record(s) at (\(latitude), \(longitude)): \(locationName ?? "nil")")

                // Reload in-memory records to reflect changes
                RecordManager.shared.loadRecordsFromHistory()
            }

            return updatedCount
        } catch {
            debugLog("❌ Failed to update location names: \(error.localizedDescription)")
            return 0
        }
    }

    func deleteRecord(recordId: UUID) {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", recordId as CVarArg)
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let entry = results.first {
                context.delete(entry)
                try context.save()
            }
        } catch {
            let message = "Failed to delete record: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Delete all records with the same recordType, timestamp, and approximate coordinates
    /// This handles deleting all timeframe variants of the same photo import
    /// - Returns: Number of records deleted
    @discardableResult
    func deleteRelatedRecords(recordType: String, timestamp: Date, coordinate: CLLocationCoordinate2D) -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        // Match by recordType and timestamp (same photo = same timestamp)
        // Use a small time window (1 second) to account for any rounding
        let timeWindow: TimeInterval = 1.0
        let startTime = timestamp.addingTimeInterval(-timeWindow)
        let endTime = timestamp.addingTimeInterval(timeWindow)

        request.predicate = NSPredicate(
            format: "recordType == %@ AND timestamp >= %@ AND timestamp <= %@",
            recordType,
            startTime as NSDate,
            endTime as NSDate
        )

        do {
            let results = try context.fetch(request)

            // Filter to only records at the same coordinates (within tolerance)
            let tolerance = 0.0001 // ~11 meters
            let matchingRecords = results.filter { entry in
                abs(entry.latitude - coordinate.latitude) < tolerance &&
                abs(entry.longitude - coordinate.longitude) < tolerance
            }

            for entry in matchingRecords {
                context.delete(entry)
            }

            if !matchingRecords.isEmpty {
                try context.save()
            }

            return matchingRecords.count
        } catch {
            let message = "Failed to delete related records: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
            return 0
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
                        debugLog("🗑️ Consolidating: Removed \(record.recordType ?? unknownValueString) (\(record.timeFrame ?? unknownValueString)) with value \(record.value)")
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

            // Clear cached thumbnails
            ThumbnailCache.shared.clearAllThumbnails()
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

        // Clear daily statistics as well (even for local-only clear)
        DailyStatisticManager.shared.clearAllStatistics()

        // Clear cached thumbnails (will regenerate on app launch after iCloud sync)
        ThumbnailCache.shared.clearAllThumbnails()

        // Reset the managed object context to release all cached objects
        // This prevents crashes when FetchRequests hold stale references
        context.reset()

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
                    DispatchQueue.main.async {
                        if let error = error {
                            debugLog("❌ Failed to reload store: \(error.localizedDescription)")
                        } else {
                            debugLog("✅ Store reloaded - iCloud sync will restore data")
                            // Reload records from the fresh store
                            RecordManager.shared.loadRecordsFromHistory()
                        }
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
