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

    /// Get the furthest record for a given type and time frame
    /// Used for displaying location summaries in statistics charts
    /// - Parameters:
    ///   - type: The record type (e.g., "Furthest North")
    ///   - timeFrame: The time frame to query
    /// - Returns: A simple struct with value and location name, or nil if no record found
    func getFurthestRecord(type: String, timeFrame: TimeFrame) -> (value: Double, locationName: String?)? {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        // Build predicate based on time frame
        let calendar = Calendar.current
        let now = Date()

        switch timeFrame {
        case .month:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@",
                type, monthStart as NSDate, monthEnd as NSDate
            )
        case .year:
            let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now))!
            let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart)!
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@",
                type, yearStart as NSDate, yearEnd as NSDate
            )
        case .allTime:
            // For all-time, query ALL records of this type regardless of stored timeFrame
            // This finds the most extreme value ever recorded
            request.predicate = NSPredicate(
                format: "recordType == %@",
                type
            )
        }

        // Sort to get the most extreme value
        // North/East/Up: highest value; South/West: lowest value
        let isHighestWins = type.contains("North") || type.contains("East") || type.contains("Up") || type.contains("Furthest from Home")
        request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: !isHighestWins)]
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let record = results.first {
                return (value: record.value, locationName: record.locationName)
            }
        } catch {
            debugLog("❌ Failed to get furthest record: \(error.localizedDescription)")
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

            // Clear daily statistics
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
    /// Returns true if successful
    @discardableResult
    func clearLocalOnly() -> Bool {
        debugLog("🗑️ Starting local-only clear...")

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
            PersistenceController.shared.container.loadPersistentStores { description, error in
                DispatchQueue.main.async {
                    if let error = error {
                        debugLog("❌ Failed to reload store: \(error.localizedDescription)")
                    } else {
                        debugLog("✅ Store reloaded - waiting for iCloud sync to restore data")
                        // DON'T load records here - wait for iCloud sync to complete first
                        // The caller should monitor sync completion and then reload
                    }
                }
            }

            return true
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

        request.predicate = NSPredicate(
            format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@",
            type,
            yearStart as NSDate,
            yearEnd as NSDate
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

        request.predicate = NSPredicate(
            format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@",
            type,
            monthStart as NSDate,
            monthEnd as NSDate
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

    /// Delete records for a specific type and time period
    /// Used when user skips an existing record (to clear it)
    @discardableResult
    func deleteRecords(type: String, year: Int, month: Int? = nil) -> Int {
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
            format: "recordType == %@ AND timestamp >= %@ AND timestamp < %@",
            type,
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
                debugLog("🗑️ Deleted \(count) record(s) for \(type) in \(year)\(month != nil ? "-\(month!)" : "")")
            }
            return count
        } catch {
            debugLog("❌ Error deleting records: \(error.localizedDescription)")
            return 0
        }
    }

    /// Delete all records of a specific type (for clearing all-time records)
    /// - Parameter type: The record type (e.g., "Furthest North")
    /// - Returns: The number of records deleted
    @discardableResult
    func deleteAllRecords(type: String) -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "recordType == %@", type)

        do {
            let results = try context.fetch(request)
            let count = results.count
            for record in results {
                context.delete(record)
            }
            if count > 0 {
                try context.save()
                debugLog("🗑️ Deleted all \(count) record(s) for \(type)")
            }
            return count
        } catch {
            debugLog("❌ Error deleting all records: \(error.localizedDescription)")
            return 0
        }
    }
}
