import CoreData
import CoreLocation
import SwiftUI

/// RecordHistoryManager: Core Data persistence for geographical records
///
/// **Error Handling Policy:**
/// - **Data consistency errors** (save failures, constraint violations): Show alert to user via showError/errorMessage
/// - **Transient errors** (fetch failures, temporary issues): Log only with debugLog()
/// - **Expected conditions** (duplicate records, no data): Silent or info-level logging
/// - **User-facing operations** (import, delete, restore): Always alert on failure
@MainActor
class RecordHistoryManager: ObservableObject {
    static let shared = RecordHistoryManager()

    @Published var errorMessage: String?
    @Published var showError: Bool = false

    private var context: NSManagedObjectContext {
        dispatchPrecondition(condition: .onQueue(.main))
        return PersistenceController.shared.container.viewContext
    }

    /// Add a record to Core Data history
    /// - Returns: true if successful, false if failed (duplicate or save error)
    @discardableResult
    func addRecord(recordType: String, detail: RecordDetail) -> Bool {
        // Check if this record already exists to prevent duplicates
        if recordExists(recordType: recordType, detail: detail) {
            debugLog("⚠️ Duplicate record detected and skipped: \(recordType) (\(detail.timeFrame.rawValue)) at \(detail.timestamp)")
            return false
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
        newEntry.source = detail.source?.rawValue
        newEntry.regionCode = detail.regionCode

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
            return true
        } catch {
            let message = "Failed to save record: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
            return false
        }
    }

    /// Check if a record already exists (prevents duplicates from imports/syncs)
    private func recordExists(recordType: String, detail: RecordDetail) -> Bool {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        // Calculate date range for comparison using shared tolerance constants
        let timestampMin = detail.timestamp.addingTimeInterval(-duplicateTimeToleranceSeconds)
        let timestampMax = detail.timestamp.addingTimeInterval(duplicateTimeToleranceSeconds)
        let valueMin = detail.value - duplicateValueTolerance
        let valueMax = detail.value + duplicateValueTolerance
        let latMin = detail.coordinate.latitude - duplicateCoordinateToleranceDegrees
        let latMax = detail.coordinate.latitude + duplicateCoordinateToleranceDegrees
        let lonMin = detail.coordinate.longitude - duplicateCoordinateToleranceDegrees
        let lonMax = detail.coordinate.longitude + duplicateCoordinateToleranceDegrees

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

    // MARK: - Fetch Request Helpers
    // TODO: Add unit tests for these helper methods when test coverage is expanded

    /// Fetch the first record matching a predicate
    /// Encapsulates common NSFetchRequest pattern to reduce code duplication
    /// - Parameters:
    ///   - predicate: The predicate to filter records (e.g., `NSPredicate(format: "id == %@", uuid)`)
    ///   - sortDescriptors: Optional sort descriptors (defaults to none)
    /// - Returns: The first matching record, or nil if none found or error occurred
    /// - Note: Returns nil on fetch errors (logged via debugLog) for safe failure handling
    private func fetchFirstRecord(
        predicate: NSPredicate,
        sortDescriptors: [NSSortDescriptor]? = nil
    ) -> RecordHistoryEntry? {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = predicate
        request.fetchLimit = 1
        request.sortDescriptors = sortDescriptors

        do {
            return try context.fetch(request).first
        } catch {
            debugLog("❌ Fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch all records matching a predicate
    /// Encapsulates common NSFetchRequest pattern for multi-record queries
    /// - Parameters:
    ///   - predicate: The predicate to filter records (e.g., `NSPredicate(format: "recordType == %@", type)`)
    ///   - sortDescriptors: Optional sort descriptors (e.g., `[NSSortDescriptor(key: "timestamp", ascending: false)]`)
    /// - Returns: Array of matching records (empty if none found or error occurred)
    /// - Note: Returns empty array on fetch errors (logged via debugLog) for safe iteration
    private func fetchRecords(
        predicate: NSPredicate,
        sortDescriptors: [NSSortDescriptor]? = nil
    ) -> [RecordHistoryEntry] {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors

        do {
            return try context.fetch(request)
        } catch {
            debugLog("❌ Fetch error: \(error.localizedDescription)")
            return []
        }
    }

    /// Delete all records matching a predicate
    /// Encapsulates common NSFetchRequest + delete pattern
    /// - Parameter predicate: The predicate to filter records (e.g., `NSPredicate(format: "timeFrame == %@", "Daily")`)
    /// - Returns: Number of records deleted, or 0 if error occurred
    /// - Note: Automatically saves context after deletion; returns 0 on save errors (logged via debugLog)
    @discardableResult
    private func deleteRecords(predicate: NSPredicate) -> Int {
        let records = fetchRecords(predicate: predicate)
        let count = records.count

        for record in records {
            context.delete(record)
        }

        do {
            try context.save()
            return count
        } catch {
            debugLog("❌ Delete error: \(error.localizedDescription)")
            return 0
        }
    }

    func updateRecordPhoto(recordId: UUID, photoData: Data?) {
        guard let entry = fetchFirstRecord(predicate: NSPredicate(format: "id == %@", recordId as CVarArg)) else {
            debugLog("⚠️ Record not found with id: \(recordId)")
            return
        }

        do {
            entry.photoData = photoData
            try context.save()
        } catch {
            let message = "Failed to update photo: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Update the photo asset identifier for a record
    /// Also updates the cloud identifier for cross-device sync
    func updateRecordPhotoAsset(recordId: UUID, localIdentifier: String, cloudIdentifier: String?) {
        guard let entry = fetchFirstRecord(predicate: NSPredicate(format: "id == %@", recordId as CVarArg)) else {
            debugLog("⚠️ Record not found with id: \(recordId)")
            return
        }

        do {
            entry.photoAssetIdentifier = localIdentifier
            entry.photoCloudIdentifier = cloudIdentifier
            // Clear legacy photo data since we're using asset reference now
            entry.photoData = nil
            try context.save()
            debugLog("📸 Updated photo for record \(recordId)")
        } catch {
            let message = "Failed to update photo asset: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    func updateRecordNotes(recordId: UUID, notes: String?) {
        guard let entry = fetchFirstRecord(predicate: NSPredicate(format: "id == %@", recordId as CVarArg)) else {
            debugLog("⚠️ Record not found with id: \(recordId)")
            return
        }

        do {
            entry.notes = notes
            try context.save()
        } catch {
            let message = "Failed to update notes: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }

    /// Update the location name for a specific record
    func updateRecordLocationName(recordId: UUID, locationName: String?) {
        guard let entry = fetchFirstRecord(predicate: NSPredicate(format: "id == %@", recordId as CVarArg)) else {
            debugLog("⚠️ Record not found with id: \(recordId)")
            return
        }

        do {
            entry.locationName = locationName
            try context.save()
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

        let latMin = latitude - locationNameProximityToleranceDegrees
        let latMax = latitude + locationNameProximityToleranceDegrees
        let lonMin = longitude - locationNameProximityToleranceDegrees
        let lonMax = longitude + locationNameProximityToleranceDegrees

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

    /// Get the furthest record for a given type and time frame
    /// Used for displaying location summaries in statistics charts
    /// - Parameters:
    ///   - type: The record type (e.g., "Furthest North")
    ///   - timeFrame: The time frame to query
    /// - Returns: A tuple with value and location name, or nil if no record found
    func getFurthestRecord(type: String, timeFrame: TimeFrame) -> (value: Double, locationName: String?)? {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        // Build predicate based on time frame - filter by timeFrame field to match Records tab
        let calendar = Calendar.current
        let now = Date()

        switch timeFrame {
        case .daily:
            let dayStart = calendar.startOfDay(for: now)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                debugLog("❌ Failed to calculate day end date")
                return nil
            }
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timeFrame == %@ AND timestamp >= %@ AND timestamp < %@",
                type, "Daily", dayStart as NSDate, dayEnd as NSDate
            )
        case .month:
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                debugLog("❌ Failed to calculate month date range")
                return nil
            }
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timeFrame == %@ AND timestamp >= %@ AND timestamp < %@",
                type, "Monthly", monthStart as NSDate, monthEnd as NSDate
            )
        case .year:
            guard let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now)),
                  let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart) else {
                debugLog("❌ Failed to calculate year date range")
                return nil
            }
            // Include both Yearly AND Monthly records from current year (Monthly is part of this year)
            request.predicate = NSPredicate(
                format: "recordType == %@ AND (timeFrame == %@ OR timeFrame == %@) AND timestamp >= %@ AND timestamp < %@",
                type, "Yearly", "Monthly", yearStart as NSDate, yearEnd as NSDate
            )
        case .allTime:
            // For all-time, query only Lifetime records (handles all historical variations)
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timeFrame IN %@",
                type, lifetimeTimeFrameVariations
            )
        }

        do {
            let results = try context.fetch(request)
            // Same slot rule as RecordManager.loadRecordsFromHistory (wizard choice,
            // else extreme) — Stats and Records tabs must agree
            if let recordType = RecordType.from(string: type),
               let record = recordType.displayRecord(of: results, slotTimeFrame: timeFrame) {
                return (value: record.value, locationName: record.locationName)
            }
        } catch {
            debugLog("❌ Failed to get furthest record: \(error.localizedDescription)")
        }

        return nil
    }

    /// Get the record for a given type within a specific year
    /// Used for displaying location summaries when a specific year is selected
    /// - Parameters:
    ///   - type: The record type (e.g., "Furthest North")
    ///   - year: The year to query
    /// - Returns: A tuple with value and location name, or nil if no record found
    func getFurthestRecordForYear(type: String, year: Int) -> (value: Double, locationName: String?)? {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        let calendar = Calendar.current
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return nil
        }

        // Include Yearly AND Monthly rows — matches the Records tab's past-year query
        // (a monthly record from that year is part of that year even without a Yearly row)
        request.predicate = NSPredicate(
            format: "recordType == %@ AND timeFrame IN %@ AND timestamp >= %@ AND timestamp < %@",
            type, [TimeFrame.year.rawValue, TimeFrame.month.rawValue], yearStart as NSDate, yearEnd as NSDate
        )

        do {
            let results = try context.fetch(request)
            // Same slot rule as everywhere else — see getFurthestRecord
            if let recordType = RecordType.from(string: type),
               let record = recordType.displayRecord(of: results, slotTimeFrame: .year) {
                return (value: record.value, locationName: record.locationName)
            }
        } catch {
            debugLog("❌ Failed to get furthest record for year: \(error.localizedDescription)")
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

        let latMin = latitude - locationNameProximityToleranceDegrees
        let latMax = latitude + locationNameProximityToleranceDegrees
        let lonMin = longitude - locationNameProximityToleranceDegrees
        let lonMax = longitude + locationNameProximityToleranceDegrees

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
    /// For Lifetime records: keeps only the single most extreme
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
                case _ where lifetimeTimeFrameVariations.contains(timeFrameStr):
                    // Single group for lifetime records (handle all variations)
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
    /// - Returns: true if the wipe succeeded; false if the Core Data fetch/save failed
    ///   (callers that are about to re-import data MUST check this — importing on top of
    ///   a failed wipe produces duplicates)
    @discardableResult
    func clearHistory() -> Bool {
        do {
            // Delete RecordHistoryEntry records
            let recordRequest: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            let allRecords = try context.fetch(recordRequest)
            let recordCount = allRecords.count
            for record in allRecords {
                context.delete(record)
            }

            // Delete VisitedRegion records
            let regionRequest: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()
            let allRegions = try context.fetch(regionRequest)
            let regionCount = allRegions.count
            for region in allRegions {
                context.delete(region)
            }

            // Delete PhotoRegionCache records
            let cacheRequest: NSFetchRequest<PhotoRegionCache> = PhotoRegionCache.fetchRequest()
            let allCache = try context.fetch(cacheRequest)
            let cacheCount = allCache.count
            for cache in allCache {
                context.delete(cache)
            }

            try context.save()
            debugLog("✅ Deleted \(recordCount) records, \(regionCount) visited regions, \(cacheCount) cache entries (will sync to iCloud)")

            // Reset in-memory records
            RecordManager.shared.resetRecords()

            // Reload visited regions (now empty)
            RegionTrackingManager.shared.loadVisitedRegions()

            // Note: Daily records are stored in RecordHistoryEntry with timeFrame="Daily"
            // and are cleared along with other records above

            // Clear cached thumbnails
            ThumbnailCache.shared.clearAllThumbnails()
            return true
        } catch {
            let message = "Failed to clear records: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
            return false
        }
    }

    /// Clear local records only - iCloud data remains and will sync back
    /// This deletes the local SQLite file directly to avoid CloudKit sync
    /// Waits for store to fully reload before returning
    func clearLocalOnly() async -> Bool {
        debugLog("🗑️ Starting local-only clear...")

        // Reset in-memory records first
        RecordManager.shared.resetRecords()

        // Note: Daily records are stored in RecordHistoryEntry and will be cleared with the database

        // Clear cached thumbnails (will regenerate on app launch after iCloud sync)
        ThumbnailCache.shared.clearAllThumbnails()

        // Reset the managed object context to release all cached objects
        // This prevents crashes when FetchRequests hold stale references
        context.reset()

        // Get the store URL
        guard let storeDescription = PersistenceController.shared.container.persistentStoreDescriptions.first,
              let storeURL = storeDescription.url else {
            debugLog("⚠️ Could not find store URL for local clear")
            return false
        }

        debugLog("🗑️ Store URL: \(storeURL.path)")

        // Use destroyPersistentStore which properly handles CloudKit stores
        let coordinator = PersistenceController.shared.container.persistentStoreCoordinator
        do {
            // First remove the store if loaded
            if let store = coordinator.persistentStore(for: storeURL) {
                try coordinator.remove(store)
                debugLog("🗑️ Removed persistent store from coordinator")
            }

            // Destroy the store completely (this handles CloudKit metadata too)
            try coordinator.destroyPersistentStore(at: storeURL, type: .sqlite, options: nil)
            debugLog("🗑️ Destroyed persistent store at URL")

            // Also delete any leftover SQLite files (belt and suspenders)
            let fileManager = FileManager.default
            let storePath = storeURL.path
            for suffix in ["", "-shm", "-wal"] {
                let filePath = storePath + suffix
                if fileManager.fileExists(atPath: filePath) {
                    try? fileManager.removeItem(atPath: filePath)
                    debugLog("🗑️ Deleted file: \(filePath)")
                }
            }

            // Also clear CloudKit metadata cache if it exists
            let ckMetadataPath = storeURL.deletingLastPathComponent()
                .appendingPathComponent("ckAssetFiles")
            if fileManager.fileExists(atPath: ckMetadataPath.path) {
                try? fileManager.removeItem(at: ckMetadataPath)
                debugLog("🗑️ Cleared CloudKit asset cache")
            }

            debugLog("✅ Local database destroyed completely")

            // Reload the store - iCloud will sync data back fresh
            // Use continuation to wait for async completion
            return await withCheckedContinuation { continuation in
                PersistenceController.shared.container.loadPersistentStores { description, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            debugLog("❌ Failed to reload store: \(error.localizedDescription)")
                            continuation.resume(returning: false)
                        } else {
                            debugLog("✅ Store reloaded - waiting for iCloud sync to restore data")
                            // DON'T load records here - wait for iCloud sync to complete first
                            // The caller should monitor sync completion and then reload
                            continuation.resume(returning: true)
                        }
                    }
                }
            }
        } catch {
            debugLog("❌ Failed to clear local database: \(error.localizedDescription)")
            return false
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

    /// Delete all records that are within the home radius
    /// These are typically test/bogus data from when the user was at home
    /// - Returns: Number of records deleted
    @discardableResult
    func deleteRecordsAtHome() -> Int {
        guard let homeCoord = SettingsManager.shared.homeCoordinate else {
            debugLog("🏠 No home location set, skipping at-home record cleanup")
            return 0
        }

        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        do {
            let allRecords = try context.fetch(request)
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            var recordsDeleted = 0

            for record in allRecords {
                let recordLocation = CLLocation(latitude: record.latitude, longitude: record.longitude)
                let distance = recordLocation.distance(from: homeLocation)

                if distance <= atHomeRadiusMeters {
                    debugLog("🏠 Deleting record at home: \(record.recordType ?? "unknown") (\(record.timeFrame ?? "unknown")) - \(Int(distance))m from home")
                    context.delete(record)
                    recordsDeleted += 1
                }
            }

            if recordsDeleted > 0 {
                try context.save()
                debugLog("🏠 Deleted \(recordsDeleted) record(s) within \(Int(atHomeRadiusMeters))m of home")

                // Reload in-memory records to reflect changes
                RecordManager.shared.loadRecordsFromHistory()
            } else {
                debugLog("🏠 No records at home to delete")
            }

            return recordsDeleted
        } catch {
            debugLog("❌ Error deleting records at home: \(error.localizedDescription)")
            return 0
        }
    }

    /// Perform all data cleanup operations
    /// Call this at startup and after imports to ensure data consistency
    /// - Returns: Total number of records cleaned up
    @discardableResult
    func performDataCleanup() -> Int {
        debugLog("🧹 Starting data cleanup...")

        var totalCleaned = 0

        // 1. Remove exact duplicates
        let duplicatesRemoved = removeDuplicates()
        totalCleaned += duplicatesRemoved

        // 2. Delete records at home (bogus/test data)
        let atHomeDeleted = deleteRecordsAtHome()
        totalCleaned += atHomeDeleted

        // Note: consolidateRecords() is NOT called automatically
        // It should only be run on explicit user request since it removes history

        if totalCleaned > 0 {
            debugLog("🧹 Data cleanup complete: \(totalCleaned) total record(s) cleaned")
        } else {
            debugLog("🧹 Data cleanup complete: no issues found")
        }

        return totalCleaned
    }

    // MARK: - Historical Record Lookup

    /// Get the best (most extreme) record for a given type and year
    /// Used for checking if a historical yearly record exists
    /// Note: Only returns Yearly records - Lifetime and Monthly records are managed separately
    func getBestRecord(type: String, year: Int) -> RecordDetail? {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        let calendar = Calendar.current
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1

        guard let yearStart = calendar.date(from: components),
              let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart) else {
            return nil
        }

        // Query ONLY Yearly records in the year range
        // We specifically want timeFrame == "Yearly" because:
        // - Lifetime records are managed separately by the Lifetime wizard section
        // - Monthly records should not be pre-selected for the Yearly wizard section
        // This ensures the Past Years section pre-selects the actual yearly record photo,
        // not a more extreme monthly record from the same year
        request.predicate = NSPredicate(
            format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@ AND timeFrame == %@",
            type,
            yearStart as NSDate,
            yearEnd as NSDate,
            "Yearly"
        )

        // Sort by extremeness based on record type
        let ascending = type == RecordType.south.rawValue || type == RecordType.west.rawValue
        request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: ascending)]
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let entry = results.first {
                return RecordDetail(
                    value: entry.value,
                    timestamp: entry.timestamp ?? Date(),
                    coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
                    altitude: entry.altitude,
                    locationName: entry.locationName,
                    recordType: entry.recordType ?? "",
                    timeFrame: TimeFrame(rawValue: entry.timeFrame ?? "") ?? .allTime,
                    photoAssetIdentifier: entry.photoAssetIdentifier,
                    photoCloudIdentifier: entry.photoCloudIdentifier
                )
            }
        } catch {
            debugLog("❌ Error fetching best record for \(type) in \(year): \(error.localizedDescription)")
        }

        return nil
    }

    /// Get the best (most extreme) record for a given type, year, and month
    /// Used for checking if a historical monthly record exists
    /// Note: Only returns Monthly records - Lifetime and Yearly records are managed separately
    func getBestRecord(type: String, year: Int, month: Int) -> RecordDetail? {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        let calendar = Calendar.current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1

        guard let monthStart = calendar.date(from: components),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return nil
        }

        // Query ONLY Monthly records in the month range
        // We specifically want timeFrame == "Monthly" because:
        // - Lifetime records are managed separately by the Lifetime wizard section
        // - Yearly records are managed separately by the Past Years wizard section
        // This ensures the Monthly section pre-selects the actual monthly record photo
        request.predicate = NSPredicate(
            format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@ AND timeFrame == %@",
            type,
            monthStart as NSDate,
            monthEnd as NSDate,
            "Monthly"
        )

        // Sort by extremeness based on record type
        let ascending = type == RecordType.south.rawValue || type == RecordType.west.rawValue
        request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: ascending)]
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let entry = results.first {
                return RecordDetail(
                    value: entry.value,
                    timestamp: entry.timestamp ?? Date(),
                    coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
                    altitude: entry.altitude,
                    locationName: entry.locationName,
                    recordType: entry.recordType ?? "",
                    timeFrame: TimeFrame(rawValue: entry.timeFrame ?? "") ?? .month,
                    photoAssetIdentifier: entry.photoAssetIdentifier,
                    photoCloudIdentifier: entry.photoCloudIdentifier
                )
            }
        } catch {
            debugLog("❌ Error fetching best record for \(type) in \(year)-\(month): \(error.localizedDescription)")
        }

        return nil
    }

    /// Delete records for a specific type, timeframe, and time period
    /// Used when user skips an existing record (to clear it)
    /// The timeFrame predicate is essential: skipping a monthly record must not delete the
    /// yearly/lifetime/daily rows that happen to fall inside the same date window.
    @discardableResult
    func deleteRecords(type: String, timeFrame: TimeFrame, year: Int, month: Int? = nil) -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        let calendar = Calendar.current
        var components = DateComponents()
        components.year = year

        let startDate: Date
        let endDate: Date

        if let month = month {
            components.month = month
            components.day = 1
            guard let monthStart = calendar.date(from: components),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                return 0
            }
            startDate = monthStart
            endDate = monthEnd
        } else {
            components.month = 1
            components.day = 1
            guard let yearStart = calendar.date(from: components),
                  let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart) else {
                return 0
            }
            startDate = yearStart
            endDate = yearEnd
        }

        request.predicate = NSPredicate(
            format: "recordType == %@ AND timeFrame == %@ AND timestamp >= %@ AND timestamp < %@",
            type,
            timeFrame.rawValue,
            startDate as NSDate,
            endDate as NSDate
        )

        do {
            let results = try context.fetch(request)
            let count = results.count
            for record in results {
                context.delete(record)
            }
            if count > 0 {
                try context.save()
                debugLog("🗑️ Deleted \(count) record(s) for \(type) in \(year)\(month.map { "-\($0)" } ?? "")")
            }
            return count
        } catch {
            debugLog("❌ Error deleting records: \(error.localizedDescription)")
            return 0
        }
    }

    /// Delete the lifetime record(s) of a specific type (for clearing all-time records)
    /// Scoped to Lifetime rows only: clearing a lifetime record must not destroy the
    /// monthly/yearly/daily history of that record type.
    /// - Parameter type: The record type (e.g., "Furthest North")
    /// - Returns: The number of records deleted
    @discardableResult
    func deleteLifetimeRecords(type: String) -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "recordType == %@ AND timeFrame IN %@", type, lifetimeTimeFrameVariations)

        do {
            let results = try context.fetch(request)
            let count = results.count
            for record in results {
                context.delete(record)
            }
            if count > 0 {
                try context.save()
                debugLog("🗑️ Deleted \(count) lifetime record(s) for \(type)")
            }
            return count
        } catch {
            debugLog("❌ Error deleting all records: \(error.localizedDescription)")
            return 0
        }
    }

    /// Delete existing record(s) for a specific type and timeframe before importing a new one
    /// This prevents accumulation of duplicate records with different photos
    /// - Parameters:
    ///   - type: The record type (e.g., "Furthest North")
    ///   - timeFrame: The timeframe (.allTime, .year, .month)
    ///   - timestamp: The timestamp of the new record (used to determine year/month for yearly/monthly records)
    func deleteExistingRecord(type: String, timeFrame: TimeFrame, timestamp: Date) {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        let calendar = Calendar.current

        // Build predicate based on timeframe
        // Note: We check multiple timeFrame string variations to catch records saved with different formats
        switch timeFrame {
        case .allTime:
            // For all-time, delete any record of this type with timeFrame matching lifetime variations or nil/empty
            request.predicate = NSPredicate(
                format: "recordType == %@ AND (timeFrame IN %@ OR timeFrame == nil OR timeFrame == %@)",
                type, lifetimeTimeFrameVariations, ""
            )
        case .year:
            // For yearly, delete ONLY Yearly records of this type within the same year
            // We specifically target timeFrame == "Yearly" to avoid deleting:
            // - Lifetime records (managed by the Lifetime wizard section)
            // - Monthly records (managed by the Monthly wizard section)
            let year = calendar.component(.year, from: timestamp)
            guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let yearEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
                return
            }
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@ AND timeFrame == %@",
                type, yearStart as NSDate, yearEnd as NSDate, "Yearly"
            )
        case .month:
            // For monthly, delete ONLY Monthly records of this type within the same month
            // We specifically target timeFrame == "Monthly" to avoid deleting:
            // - Lifetime records (managed by the Lifetime wizard section)
            // - Yearly records (managed by the Past Years wizard section)
            // - Daily records (managed separately for statistics)
            let year = calendar.component(.year, from: timestamp)
            let month = calendar.component(.month, from: timestamp)
            guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                return
            }
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@ AND timeFrame == %@",
                type, monthStart as NSDate, monthEnd as NSDate, "Monthly"
            )
        case .daily:
            // Don't delete daily records during wizard import
            return
        }

        do {
            let results = try context.fetch(request)
            if !results.isEmpty {
                for record in results {
                    // Delete cached thumbnail
                    if let id = record.id {
                        ThumbnailCache.shared.deleteThumbnail(for: id)
                    }
                    context.delete(record)
                }
                try context.save()
                debugLog("🗑️ Deleted \(results.count) existing \(type) record(s) for \(timeFrame.rawValue) before import")
            }
        } catch {
            debugLog("❌ Error deleting existing record: \(error.localizedDescription)")
        }
    }

    // MARK: - Aggregate Queries for Statistics

    /// Get all years that have record history data
    /// - Returns: Array of years sorted descending (most recent first)
    func getAvailableYears() -> [Int] {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        do {
            let results = try context.fetch(request)
            let calendar = Calendar.current
            let years = Set(results.compactMap { entry -> Int? in
                guard let date = entry.timestamp else { return nil }
                return calendar.component(.year, from: date)
            })
            return years.sorted(by: >)
        } catch {
            debugLog("❌ Error fetching available years: \(error.localizedDescription)")
            return []
        }
    }

    /// Get monthly aggregates for a specific year from RecordHistoryEntry
    /// Groups records by month and finds the extreme value for each record type
    /// - Parameter year: The year to query
    /// - Returns: Array of MonthlyAggregate sorted by month
    func getMonthlyAggregates(for year: Int) -> [MonthlyAggregate] {
        let calendar = Calendar.current
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return []
        }

        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        // Only include "Monthly" records - this matches what Records tab shows
        request.predicate = NSPredicate(
            format: "timestamp >= %@ AND timestamp < %@ AND timeFrame == %@",
            yearStart as NSDate,
            yearEnd as NSDate,
            "Monthly"
        )

        do {
            let records = try context.fetch(request)

            // Group by month
            var monthlyData: [Int: [RecordHistoryEntry]] = [:]
            for record in records {
                guard let timestamp = record.timestamp else { continue }
                let month = calendar.component(.month, from: timestamp)
                monthlyData[month, default: []].append(record)
            }

            // Build aggregates for each month
            return monthlyData.map { month, monthRecords in
                buildMonthlyAggregate(year: year, month: month, records: monthRecords)
            }.sorted { $0.month < $1.month }
        } catch {
            debugLog("❌ Error fetching monthly aggregates: \(error.localizedDescription)")
            return []
        }
    }

    /// Get yearly aggregates from RecordHistoryEntry records
    /// Only includes "Yearly" records to match what the Records tab shows for past years
    /// - Returns: Array of YearlyAggregate sorted by year
    func getYearlyAggregates() -> [YearlyAggregate] {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        // Only include "Yearly" records - this matches what Records tab shows for past years
        request.predicate = NSPredicate(format: "timeFrame == %@", "Yearly")
        let calendar = Calendar.current

        do {
            let records = try context.fetch(request)

            // Group by year
            var yearlyData: [Int: [RecordHistoryEntry]] = [:]
            for record in records {
                guard let timestamp = record.timestamp else { continue }
                let year = calendar.component(.year, from: timestamp)
                yearlyData[year, default: []].append(record)
            }

            // Build aggregates for each year
            return yearlyData.map { year, yearRecords in
                buildYearlyAggregate(year: year, records: yearRecords)
            }.sorted { $0.year < $1.year }
        } catch {
            debugLog("❌ Error fetching yearly aggregates: \(error.localizedDescription)")
            return []
        }
    }

    /// Build a MonthlyAggregate from a set of records
    private func buildMonthlyAggregate(year: Int, month: Int, records: [RecordHistoryEntry]) -> MonthlyAggregate {
        let extremes = ExtractedExtremes.extract(from: records)
        return MonthlyAggregate(
            year: year,
            month: month,
            maxNorth: extremes.maxNorth,
            maxSouth: extremes.maxSouth,
            maxEast: extremes.maxEast,
            maxWest: extremes.maxWest,
            maxUp: extremes.maxUp,
            maxDistanceFromHome: extremes.maxDistanceFromHome
        )
    }

    /// Build a YearlyAggregate from a set of records
    private func buildYearlyAggregate(year: Int, records: [RecordHistoryEntry]) -> YearlyAggregate {
        let extremes = ExtractedExtremes.extract(from: records)
        return YearlyAggregate(
            year: year,
            maxNorth: extremes.maxNorth,
            maxSouth: extremes.maxSouth,
            maxEast: extremes.maxEast,
            maxWest: extremes.maxWest,
            maxUp: extremes.maxUp,
            maxDistanceFromHome: extremes.maxDistanceFromHome
        )
    }

    // MARK: - Daily Record Management

    /// Update or create a daily record for a specific date and record type
    /// Daily records track the extreme value for each day (used for "This Month" charts)
    /// - Parameters:
    ///   - recordType: The record type (e.g., .north)
    ///   - value: The new value to compare against existing
    ///   - location: The location where this value was recorded
    ///   - locationName: Optional reverse-geocoded name
    ///   - date: The date for this daily record (defaults to today)
    func updateDailyRecord(
        recordType: RecordType,
        value: Double,
        location: CLLocation,
        locationName: String?,
        date: Date = Date()
    ) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            debugLog("❌ Failed to calculate day end date for daily record update")
            return
        }

        // Check if we already have a daily record for this type and date
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "recordType == %@ AND timeFrame == %@ AND timestamp >= %@ AND timestamp < %@",
            recordType.rawValue,
            TimeFrame.daily.rawValue,
            dayStart as NSDate,
            dayEnd as NSDate
        )
        request.fetchLimit = 1

        do {
            let existing = try context.fetch(request).first

            if let existing = existing {
                // Check if new value is better
                let shouldUpdate = recordType.shouldReplace(newValue: value, oldValue: existing.value)
                if shouldUpdate {
                    existing.value = value
                    existing.latitude = location.coordinate.latitude
                    existing.longitude = location.coordinate.longitude
                    existing.altitude = location.altitude
                    existing.locationName = locationName
                    try context.save()
                }
            } else {
                // Create new daily record
                let newEntry = RecordHistoryEntry(context: context)
                newEntry.id = UUID()
                newEntry.timestamp = date
                newEntry.dateAdded = Date()
                newEntry.recordType = recordType.rawValue
                newEntry.timeFrame = TimeFrame.daily.rawValue
                newEntry.value = value
                newEntry.latitude = location.coordinate.latitude
                newEntry.longitude = location.coordinate.longitude
                newEntry.altitude = location.altitude
                newEntry.locationName = locationName
                try context.save()
            }
        } catch {
            debugLog("❌ Error updating daily record: \(error.localizedDescription)")
        }
    }

    /// Updates all daily records for a location (N, S, E, W, altitude, distance from home)
    ///
    /// This is the single source of truth for daily record updates - called by both:
    /// - `RecordManager` for live location updates
    /// - `PhotoLibraryScanner` for photo imports
    ///
    /// Daily records track the extreme value for each day and are used for "This Month" charts.
    /// Old daily records (older than current month) are automatically cleaned up.
    ///
    /// - Parameters:
    ///   - location: The location to record
    ///   - locationName: Optional reverse-geocoded name
    ///   - date: The date for the record (defaults to now)
    ///   - homeCoordinate: Optional home coordinate for distance calculation
    func updateAllDailyRecords(
        location: CLLocation,
        locationName: String? = nil,
        date: Date = Date(),
        homeCoordinate: CLLocationCoordinate2D? = nil
    ) {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let alt = location.altitude

        // Update directional extremes
        updateDailyRecord(recordType: .north, value: lat, location: location, locationName: locationName, date: date)
        updateDailyRecord(recordType: .south, value: lat, location: location, locationName: locationName, date: date)
        updateDailyRecord(recordType: .east, value: lon, location: location, locationName: locationName, date: date)
        updateDailyRecord(recordType: .west, value: lon, location: location, locationName: locationName, date: date)

        // Update altitude (skip unrealistic values)
        if alt <= maxRealisticAltitudeMeters {
            updateDailyRecord(recordType: .up, value: alt, location: location, locationName: locationName, date: date)
        }

        // Update distance from home
        if let homeCoord = homeCoordinate {
            let distance = distanceBetween(from: location.coordinate, to: homeCoord)
            updateDailyRecord(recordType: .fromHome, value: distance, location: location, locationName: locationName, date: date)
        }
    }

    /// Fetch daily records for the current month (for "This Month" charts)
    /// - Returns: Dictionary mapping day of month to array of records for that day
    func getDailyRecordsForCurrentMonth() -> [Int: [RecordHistoryEntry]] {
        let calendar = Calendar.current
        guard let monthStart = calendar.dateInterval(of: .month, for: Date())?.start,
              let monthEnd = calendar.dateInterval(of: .month, for: Date())?.end else {
            return [:]
        }

        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "timeFrame == %@ AND timestamp >= %@ AND timestamp < %@",
            TimeFrame.daily.rawValue,
            monthStart as NSDate,
            monthEnd as NSDate
        )

        do {
            let records = try context.fetch(request)

            // Group by day of month
            var result: [Int: [RecordHistoryEntry]] = [:]
            for record in records {
                guard let timestamp = record.timestamp else { continue }
                let day = calendar.component(.day, from: timestamp)
                result[day, default: []].append(record)
            }
            return result
        } catch {
            debugLog("❌ Error fetching daily records: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Clean up old daily records (older than current month)
    /// Called on Stats tab appearance and app launch
    func cleanupOldDailyRecords() {
        let calendar = Calendar.current
        guard let monthStart = calendar.dateInterval(of: .month, for: Date())?.start else {
            return
        }

        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "timeFrame == %@ AND timestamp < %@",
            TimeFrame.daily.rawValue,
            monthStart as NSDate
        )

        do {
            let oldRecords = try context.fetch(request)
            if oldRecords.isEmpty { return }

            let count = oldRecords.count
            for record in oldRecords {
                context.delete(record)
            }
            try context.save()
            debugLog("🧹 Cleaned up \(count) old daily records (before \(monthStart))")
        } catch {
            debugLog("❌ Error cleaning up old daily records: \(error.localizedDescription)")
        }
    }

    /// Get a structured daily aggregate for a specific day (for chart display)
    /// - Parameter day: Day of month (1-31)
    /// - Parameter records: Dictionary from getDailyRecordsForCurrentMonth()
    /// - Returns: A DailyAggregate with extreme values for that day
    func getDailyAggregate(for day: Int, from records: [Int: [RecordHistoryEntry]]) -> DailyAggregate {
        guard let dayRecords = records[day] else {
            return DailyAggregate(day: day)
        }

        // Extract using most recently added record (for daily, there's typically one per type)
        let extremes = ExtractedExtremes.extract(from: dayRecords)
        return DailyAggregate(
            day: day,
            maxNorth: extremes.maxNorth,
            maxSouth: extremes.maxSouth,
            maxEast: extremes.maxEast,
            maxWest: extremes.maxWest,
            maxUp: extremes.maxUp,
            maxDistanceFromHome: extremes.maxDistanceFromHome
        )
    }
}

// MARK: - Aggregate Extraction Helper

/// Extracted values from a set of records (internal helper)
private struct ExtractedExtremes {
    var maxNorth: Double?
    var maxSouth: Double?
    var maxEast: Double?
    var maxWest: Double?
    var maxUp: Double?
    var maxDistanceFromHome: Double?

    /// Extract values from records using the most extreme record for each type
    /// (dateAdded only breaks ties) — must agree with RecordManager.loadRecordsFromHistory
    /// - Parameter records: The records to extract from
    static func extract(from records: [RecordHistoryEntry]) -> ExtractedExtremes {
        var result = ExtractedExtremes()

        // Group records by type
        let grouped = Dictionary(grouping: records) { $0.recordType ?? "" }

        for (recordTypeString, typeRecords) in grouped {
            guard let type = RecordType.from(string: recordTypeString) else { continue }

            guard let record = type.mostExtreme(of: typeRecords) else { continue }
            let value = record.value

            switch type {
            case .north:
                result.maxNorth = value
            case .south:
                result.maxSouth = value
            case .east:
                result.maxEast = value
            case .west:
                result.maxWest = value
            case .up:
                result.maxUp = value
            case .fromHome:
                result.maxDistanceFromHome = value
            case .state, .country, .continent:
                // Region records don't have extreme values to extract
                break
            }
        }

        return result
    }
}

// MARK: - Aggregate Data Structures

/// Aggregate of daily extreme values (for "This Month" charts)
struct DailyAggregate {
    let day: Int  // Day of month (1-31)
    let maxNorth: Double?
    let maxSouth: Double?
    let maxEast: Double?
    let maxWest: Double?
    let maxUp: Double?
    let maxDistanceFromHome: Double?

    init(
        day: Int,
        maxNorth: Double? = nil,
        maxSouth: Double? = nil,
        maxEast: Double? = nil,
        maxWest: Double? = nil,
        maxUp: Double? = nil,
        maxDistanceFromHome: Double? = nil
    ) {
        self.day = day
        self.maxNorth = maxNorth
        self.maxSouth = maxSouth
        self.maxEast = maxEast
        self.maxWest = maxWest
        self.maxUp = maxUp
        self.maxDistanceFromHome = maxDistanceFromHome
    }
}

/// Aggregate of monthly extreme values (for "This Year" charts)
struct MonthlyAggregate: Identifiable {
    let id = UUID()
    let year: Int
    let month: Int
    let maxNorth: Double?
    let maxSouth: Double?
    let maxEast: Double?
    let maxWest: Double?
    let maxUp: Double?
    let maxDistanceFromHome: Double?

    /// Cached month name formatter
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    var monthName: String {
        var components = DateComponents()
        components.month = month
        if let date = Calendar.current.date(from: components) {
            return MonthlyAggregate.monthFormatter.string(from: date)
        }
        return "\(month)"
    }
}

/// Aggregate of yearly extreme values (for "Lifetime" charts)
struct YearlyAggregate: Identifiable {
    let id = UUID()
    let year: Int
    let maxNorth: Double?
    let maxSouth: Double?
    let maxEast: Double?
    let maxWest: Double?
    let maxUp: Double?
    let maxDistanceFromHome: Double?
}
