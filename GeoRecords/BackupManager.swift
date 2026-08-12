import Foundation
import CoreData
import UIKit
import UserNotifications
import Photos

/// Manager for exporting and importing GeoRecords data backups
/// Backups are JSON files containing record metadata and photo asset identifiers
@MainActor
class BackupManager {
    static let shared = BackupManager()

    private init() {}

    // MARK: - Backup Data Structures

    /// Represents a single record in the backup
    struct BackupRecord: Codable {
        let id: String
        let recordType: String
        let timeFrame: String
        let value: Double
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let locationName: String?
        let photoAssetIdentifier: String?
        let photoCloudIdentifier: String?  // For cross-device photo access via iCloud Photo Library
        let notes: String?
        let regionCode: String?  // For region records (state code, country code, continent name)
        // Optional so backups from versions <= 6 still decode (restore as nil)
        let source: String?      // RecordSource rawValue — "wizard" is load-bearing for slot selection
        let dateAdded: Date?     // Preserved so tie-breaks survive a restore
    }

    /// Represents a visited region (state/country) in the backup
    struct BackupVisitedRegion: Codable {
        let regionCode: String
        let regionName: String
        let regionType: String  // "state" or "country"
        let visitDates: [Date]
    }

    /// Represents app settings in the backup (added in version 3)
    struct BackupSettings: Codable {
        let homeLatitude: Double?
        let homeLongitude: Double?
        let homeLocationName: String?
        let homeAddress: String?  // Added in version 6
        let notifyOnMonthlyRecords: Bool
        let notifyOnYearlyRecords: Bool
        let notifyOnAllTimeRecords: Bool
        let notifyOnNewRegion: Bool?  // Optional for backward compatibility with older backups
        let photoPromptsEnabled: Bool
        let inactivityReminderEnabled: Bool
        let inactivityReminderDays: Int?  // Added in version 6
        let summaryNotificationsEnabled: Bool
        let unitSystem: String  // "metric" or "imperial"
        // Threshold settings (added in version 6)
        let minLatitudeDelta: Double?
        let minLongitudeDelta: Double?
        let minAltitudeDeltaMetersImperial: Double?
        let minDistanceDeltaMetersImperial: Double?
        let minAltitudeDeltaMetersMetric: Double?
        let minDistanceDeltaMetersMetric: Double?
    }

    /// Represents a processed photo cache entry (added in version 5)
    struct BackupPhotoCache: Codable {
        let id: String
        let photoLocalIdentifier: String?
        let photoCloudIdentifier: String?
        let photoDate: Date?
        let photoLatitude: Double
        let photoLongitude: Double
        let regionCode: String?
        let processedDate: Date?
    }

    /// The complete backup file structure
    struct BackupFile: Codable {
        let version: Int
        let exportDate: Date
        let appVersion: String
        let deviceName: String
        let recordCount: Int
        let records: [BackupRecord]
        // Added in version 2
        let visitedRegionCount: Int?
        let visitedRegions: [BackupVisitedRegion]?
        // Added in version 3
        let settings: BackupSettings?
        // Added in version 5
        let photoCacheCount: Int?
        let photoCache: [BackupPhotoCache]?
    }

    // MARK: - Export

    /// Export all records to a JSON backup file
    /// - Returns: URL to the temporary backup file, or nil if export failed
    func exportBackup() async -> URL? {
        let context = PersistenceController.shared.container.viewContext

        // Fetch records
        let recordRequest: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        recordRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        // Fetch visited regions
        let regionRequest: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()
        regionRequest.sortDescriptors = [NSSortDescriptor(key: "regionCode", ascending: true)]

        // Fetch photo cache (tracks processed photos)
        let cacheRequest: NSFetchRequest<PhotoRegionCache> = PhotoRegionCache.fetchRequest()
        cacheRequest.sortDescriptors = [NSSortDescriptor(key: "processedDate", ascending: false)]

        do {
            let entries = try context.fetch(recordRequest)
            let regions = try context.fetch(regionRequest)
            let cacheEntries = try context.fetch(cacheRequest)

            // Convert records to backup format
            let backupRecords = entries.compactMap { entry -> BackupRecord? in
                guard let id = entry.id,
                      let recordType = entry.recordType,
                      let timeFrame = entry.timeFrame,
                      let timestamp = entry.timestamp else {
                    return nil
                }

                return BackupRecord(
                    id: id.uuidString,
                    recordType: recordType,
                    timeFrame: timeFrame,
                    value: entry.value,
                    timestamp: timestamp,
                    latitude: entry.latitude,
                    longitude: entry.longitude,
                    altitude: entry.altitude,
                    locationName: entry.locationName,
                    photoAssetIdentifier: entry.photoAssetIdentifier,
                    photoCloudIdentifier: entry.photoCloudIdentifier,
                    notes: entry.notes,
                    regionCode: entry.regionCode,
                    source: entry.source,
                    dateAdded: entry.dateAdded
                )
            }

            // Convert visited regions to backup format
            let backupRegions = regions.compactMap { region -> BackupVisitedRegion? in
                guard let code = region.regionCode,
                      let name = region.regionName,
                      let type = region.regionType else {
                    return nil
                }

                // visitDates is stored as a Transformable [Date] array
                let dates = (region.visitDates as? [Date]) ?? []

                return BackupVisitedRegion(
                    regionCode: code,
                    regionName: name,
                    regionType: type,
                    visitDates: dates
                )
            }

            // Convert photo cache to backup format
            let backupCache = cacheEntries.compactMap { cache -> BackupPhotoCache? in
                guard let id = cache.id else {
                    return nil
                }

                return BackupPhotoCache(
                    id: id.uuidString,
                    photoLocalIdentifier: cache.photoLocalIdentifier,
                    photoCloudIdentifier: cache.photoCloudIdentifier,
                    photoDate: cache.photoDate,
                    photoLatitude: cache.photoLatitude,
                    photoLongitude: cache.photoLongitude,
                    regionCode: cache.regionCode,
                    processedDate: cache.processedDate
                )
            }

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            let deviceName = UIDevice.current.name

            // Export settings
            let settingsManager = SettingsManager.shared
            let backupSettings = BackupSettings(
                homeLatitude: settingsManager.homeCoordinate?.latitude,
                homeLongitude: settingsManager.homeCoordinate?.longitude,
                homeLocationName: settingsManager.homeLocationName,
                homeAddress: settingsManager.homeAddress,
                notifyOnMonthlyRecords: settingsManager.notifyOnMonthlyRecords,
                notifyOnYearlyRecords: settingsManager.notifyOnYearlyRecords,
                notifyOnAllTimeRecords: settingsManager.notifyOnAllTimeRecords,
                notifyOnNewRegion: settingsManager.notifyOnNewRegion,
                photoPromptsEnabled: settingsManager.photoPromptsEnabled,
                inactivityReminderEnabled: settingsManager.inactivityReminderEnabled,
                inactivityReminderDays: settingsManager.inactivityReminderDays,
                summaryNotificationsEnabled: settingsManager.summaryNotificationsEnabled,
                unitSystem: settingsManager.unitSystem.rawValue,
                minLatitudeDelta: settingsManager.minLatitudeDelta,
                minLongitudeDelta: settingsManager.minLongitudeDelta,
                minAltitudeDeltaMetersImperial: settingsManager.minAltitudeDeltaMetersImperial,
                minDistanceDeltaMetersImperial: settingsManager.minDistanceDeltaMetersImperial,
                minAltitudeDeltaMetersMetric: settingsManager.minAltitudeDeltaMetersMetric,
                minDistanceDeltaMetersMetric: settingsManager.minDistanceDeltaMetersMetric
            )

            let backup = BackupFile(
                version: 7,  // v7 adds record source + dateAdded (wizard markers survive restore)
                exportDate: Date(),
                appVersion: appVersion,
                deviceName: deviceName,
                recordCount: backupRecords.count,
                records: backupRecords,
                visitedRegionCount: backupRegions.count,
                visitedRegions: backupRegions,
                settings: backupSettings,
                photoCacheCount: backupCache.count,
                photoCache: backupCache
            )

            // Encode to JSON
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let jsonData = try encoder.encode(backup)

            // Write to temp file with .georecords extension
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            let fileName = "GeoRecords_Backup_\(timestamp).georecords"

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try jsonData.write(to: tempURL)

            debugLog("✅ Backup exported: \(backupRecords.count) records, \(backupRegions.count) visited regions, \(backupCache.count) photo cache entries to \(fileName)")
            return tempURL

        } catch {
            debugLog("❌ Backup export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Safety Snapshots

    /// Directory holding automatic pre-destructive-operation snapshots
    private var safetyBackupDirectory: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent("SafetyBackups", isDirectory: true)
    }

    private static let maxSafetySnapshots = 5

    /// Write an automatic backup snapshot before a destructive operation (restore,
    /// Delete All, local reset). Best-effort: failure never blocks the operation, but a
    /// successful snapshot gives the user a local restore point in Files if a wipe or
    /// restore goes wrong. Keeps the newest few snapshots and prunes the rest.
    @discardableResult
    func writeSafetySnapshot(reason: String) async -> URL? {
        // Nothing worth snapshotting in an empty store
        let context = PersistenceController.shared.container.viewContext
        let recordCount = (try? context.count(for: RecordHistoryEntry.fetchRequest())) ?? 0
        let regionCount = (try? context.count(for: VisitedRegion.fetchRequest())) ?? 0
        guard recordCount > 0 || regionCount > 0 else {
            debugLog("🛟 Safety snapshot skipped (\(reason)): store is empty")
            return nil
        }

        guard let directory = safetyBackupDirectory else { return nil }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            debugLog("⚠️ Safety snapshot: could not create directory: \(error.localizedDescription)")
            return nil
        }

        guard let tempURL = await exportBackup() else {
            debugLog("⚠️ Safety snapshot failed (\(reason)): export produced no file")
            return nil
        }

        let destination = directory.appendingPathComponent("Safety_\(reason)_\(tempURL.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
            pruneSafetySnapshots(in: directory)
            debugLog("🛟 Safety snapshot written: \(destination.lastPathComponent)")
            return destination
        } catch {
            debugLog("⚠️ Safety snapshot failed (\(reason)): \(error.localizedDescription)")
            return nil
        }
    }

    private func pruneSafetySnapshots(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let sorted = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        for stale in sorted.dropFirst(Self.maxSafetySnapshots) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    // MARK: - Import

    /// Import records from a backup file (replaces all existing data)
    /// Uses transaction-safe approach: validates all data first, creates rollback point, then imports
    /// - Parameter url: URL to the backup JSON file
    /// - Returns: Tuple with (records imported, regions imported, cache entries imported), or nil if import failed
    typealias ImportResult = (records: Int, regions: Int, cache: Int, failed: Int)

    /// Builds the user-facing summary for a completed restore.
    /// Centralized here so the three restore entry points (Settings, ContentView, NoRecordsView)
    /// report results identically, including partial failures.
    static func importResultMessage(for result: ImportResult) -> String {
        var parts: [String] = []
        if result.records > 0 {
            parts.append("\(result.records) record\(result.records == 1 ? "" : "s")")
        }
        if result.regions > 0 {
            parts.append("\(result.regions) visited region\(result.regions == 1 ? "" : "s")")
        }
        if result.cache > 0 {
            parts.append("\(result.cache) photo cache entr\(result.cache == 1 ? "y" : "ies")")
        }
        let summary = parts.isEmpty ? "backup data" : parts.joined(separator: ", ")
        if result.failed > 0 {
            return "Imported \(summary) from backup, but \(result.failed) record\(result.failed == 1 ? "" : "s") could not be restored."
        }
        return "Successfully imported \(summary) from backup."
    }

    func importBackup(from url: URL) async -> ImportResult? {
        do {
            // PHASE 1: Parse and validate backup file BEFORE any destructive operations
            let jsonData = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let backup = try decoder.decode(BackupFile.self, from: jsonData)

            let regionCount = backup.visitedRegionCount ?? 0
            let cacheCount = backup.photoCacheCount ?? 0
            debugLog("📥 Importing backup: version \(backup.version), \(backup.recordCount) records, \(regionCount) visited regions, \(cacheCount) photo cache entries from \(backup.deviceName)")

            // Validate version (support v1, v2, v3, v4, v5, and v6)
            guard backup.version >= 1 && backup.version <= 7 else {
                debugLog("❌ Unsupported backup version: \(backup.version)")
                return nil
            }

            // PHASE 2: Pre-validate all records can be created (catch issues before clearing data)
            var recordsToImport: [(type: String, detail: RecordDetail)] = []
            for record in backup.records {
                guard let uuid = UUID(uuidString: record.id) else {
                    debugLog("⚠️ Skipping record with invalid UUID: \(record.id)")
                    continue
                }

                // Validate coordinates are in valid ranges
                guard record.latitude >= -90 && record.latitude <= 90,
                      record.longitude >= -180 && record.longitude <= 180 else {
                    debugLog("⚠️ Skipping record with invalid coordinates: \(record.latitude), \(record.longitude)")
                    continue
                }

                let timeFrame = TimeFrame(rawValue: record.timeFrame) ?? .allTime
                // Normalize region code for US states (fixes "AL" -> "US-AL" collision with Albania)
                let isState = record.recordType == RecordType.state.rawValue
                let normalizedRegionCode = record.regionCode.map { normalizeRegionCode($0, isState: isState) }
                let detail = RecordDetail(
                    id: uuid,
                    value: record.value,
                    timestamp: record.timestamp,
                    coordinate: CLLocationCoordinate2D(
                        latitude: record.latitude,
                        longitude: record.longitude
                    ),
                    altitude: record.altitude,
                    locationName: record.locationName,
                    recordType: record.recordType,
                    timeFrame: timeFrame,
                    photoAssetIdentifier: record.photoAssetIdentifier,
                    photoCloudIdentifier: record.photoCloudIdentifier,
                    notes: record.notes,
                    dateAdded: record.dateAdded,
                    regionCode: normalizedRegionCode,
                    source: record.source.flatMap { RecordSource(rawValue: $0) }
                )
                recordsToImport.append((record.recordType, detail))
            }

            // Validate regions and normalize state codes
            var regionsToImport: [BackupVisitedRegion] = []
            if let visitedRegions = backup.visitedRegions {
                for region in visitedRegions {
                    guard !region.regionCode.isEmpty, !region.regionName.isEmpty else {
                        debugLog("⚠️ Skipping region with empty code or name")
                        continue
                    }
                    // Normalize region code for US states (fixes "AL" -> "US-AL" collision with Albania)
                    let isState = region.regionType == RegionType.state.rawValue
                    let normalizedCode = normalizeRegionCode(region.regionCode, isState: isState)
                    let normalizedRegion = BackupVisitedRegion(
                        regionCode: normalizedCode,
                        regionName: region.regionName,
                        regionType: region.regionType,
                        visitDates: region.visitDates
                    )
                    regionsToImport.append(normalizedRegion)
                }
            }

            debugLog("✓ Validation passed: \(recordsToImport.count) records, \(regionsToImport.count) regions ready to import")

            // PHASE 3: Create rollback point by saving current settings
            let settingsManager = SettingsManager.shared
            let previousHomeCoordinate = settingsManager.homeCoordinate
            let previousHomeLocationName = settingsManager.homeLocationName
            let previousHomeAddress = settingsManager.homeAddress
            let previousNotifyMonthly = settingsManager.notifyOnMonthlyRecords
            let previousNotifyYearly = settingsManager.notifyOnYearlyRecords
            let previousNotifyAllTime = settingsManager.notifyOnAllTimeRecords
            let previousNotifyNewRegion = settingsManager.notifyOnNewRegion
            let previousPhotoPrompts = settingsManager.photoPromptsEnabled
            let previousInactivityReminder = settingsManager.inactivityReminderEnabled
            let previousInactivityReminderDays = settingsManager.inactivityReminderDays
            let previousSummaryNotifications = settingsManager.summaryNotificationsEnabled
            let previousUnitSystem = settingsManager.unitSystem
            let previousMinLatDelta = settingsManager.minLatitudeDelta
            let previousMinLonDelta = settingsManager.minLongitudeDelta
            let previousMinAltImperial = settingsManager.minAltitudeDeltaMetersImperial
            let previousMinDistImperial = settingsManager.minDistanceDeltaMetersImperial
            let previousMinAltMetric = settingsManager.minAltitudeDeltaMetersMetric
            let previousMinDistMetric = settingsManager.minDistanceDeltaMetersMetric

            // PHASE 4: Clear existing data (point of no return for data, but settings can be restored)
            // Safety net first: keep a local snapshot of what's about to be replaced
            await writeSafetySnapshot(reason: "restore")

            debugLog("🗑️ Clearing existing data before restore...")
            guard RecordHistoryManager.shared.clearHistory() else {
                // Importing on top of a failed wipe would duplicate every surviving row;
                // abort while the user's existing data and settings are still intact
                debugLog("❌ Aborting restore: could not clear existing data")
                return nil
            }

            // PHASE 5: Restore settings if present (version 3+)
            if let backupSettings = backup.settings {
                debugLog("⚙️ Restoring settings from backup...")

                // Restore home location
                if let lat = backupSettings.homeLatitude, let lon = backupSettings.homeLongitude {
                    settingsManager.homeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                } else {
                    settingsManager.homeCoordinate = nil
                }
                settingsManager.homeLocationName = backupSettings.homeLocationName

                // Restore home address (version 6+)
                if let homeAddress = backupSettings.homeAddress {
                    settingsManager.homeAddress = homeAddress
                }

                // Restore notification settings
                settingsManager.notifyOnMonthlyRecords = backupSettings.notifyOnMonthlyRecords
                settingsManager.notifyOnYearlyRecords = backupSettings.notifyOnYearlyRecords
                settingsManager.notifyOnAllTimeRecords = backupSettings.notifyOnAllTimeRecords
                settingsManager.notifyOnNewRegion = backupSettings.notifyOnNewRegion ?? false  // Default for older backups
                settingsManager.photoPromptsEnabled = backupSettings.photoPromptsEnabled
                settingsManager.inactivityReminderEnabled = backupSettings.inactivityReminderEnabled

                // Restore inactivity reminder days (version 6+)
                if let reminderDays = backupSettings.inactivityReminderDays {
                    settingsManager.inactivityReminderDays = reminderDays
                }

                settingsManager.summaryNotificationsEnabled = backupSettings.summaryNotificationsEnabled

                // Restore unit system
                if let unitSystem = UnitSystem(rawValue: backupSettings.unitSystem) {
                    settingsManager.unitSystem = unitSystem
                }

                // Restore threshold settings (version 6+)
                if let minLatDelta = backupSettings.minLatitudeDelta {
                    settingsManager.minLatitudeDelta = minLatDelta
                }
                if let minLonDelta = backupSettings.minLongitudeDelta {
                    settingsManager.minLongitudeDelta = minLonDelta
                }
                if let minAltImperial = backupSettings.minAltitudeDeltaMetersImperial {
                    settingsManager.minAltitudeDeltaMetersImperial = minAltImperial
                }
                if let minDistImperial = backupSettings.minDistanceDeltaMetersImperial {
                    settingsManager.minDistanceDeltaMetersImperial = minDistImperial
                }
                if let minAltMetric = backupSettings.minAltitudeDeltaMetersMetric {
                    settingsManager.minAltitudeDeltaMetersMetric = minAltMetric
                }
                if let minDistMetric = backupSettings.minDistanceDeltaMetersMetric {
                    settingsManager.minDistanceDeltaMetersMetric = minDistMetric
                }

                settingsManager.saveSettings()
                debugLog("⚙️ Settings restored from backup")

                // Request notification permissions if any notification settings are enabled
                let hasNotificationsEnabled = backupSettings.notifyOnMonthlyRecords ||
                                             backupSettings.notifyOnYearlyRecords ||
                                             backupSettings.notifyOnAllTimeRecords ||
                                             (backupSettings.notifyOnNewRegion ?? false) ||
                                             backupSettings.summaryNotificationsEnabled ||
                                             backupSettings.inactivityReminderEnabled

                if hasNotificationsEnabled {
                    Task {
                        let center = UNUserNotificationCenter.current()
                        let notificationSettings = await center.notificationSettings()

                        // Only request if permissions haven't been determined yet
                        if notificationSettings.authorizationStatus == .notDetermined {
                            do {
                                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                                debugLog("📱 Notification permissions requested after backup restore - granted: \(granted)")
                            } catch {
                                debugLog("❌ Failed to request notification permissions after restore: \(error.localizedDescription)")
                            }
                        } else {
                            debugLog("📱 Notification status after restore: \(notificationSettings.authorizationStatus.rawValue)")
                        }
                    }
                }
            }

            // PHASE 6: Import all validated records
            var importedRecordCount = 0
            var failedRecordCount = 0
            let context = PersistenceController.shared.container.viewContext

            for (recordType, detail) in recordsToImport {
                if RecordHistoryManager.shared.addRecord(recordType: recordType, detail: detail) {
                    importedRecordCount += 1
                } else {
                    failedRecordCount += 1
                }
            }
            if failedRecordCount > 0 {
                debugLog("⚠️ \(failedRecordCount) of \(recordsToImport.count) records failed to import")
            }

            // PHASE 7: Import validated regions
            var importedRegionCount = 0
            for backupRegion in regionsToImport {
                let newRegion = VisitedRegion(context: context)
                newRegion.regionCode = backupRegion.regionCode
                newRegion.regionName = backupRegion.regionName
                newRegion.regionType = backupRegion.regionType
                newRegion.visitDates = backupRegion.visitDates.sorted() as NSArray
                importedRegionCount += 1
            }

            // PHASE 7.5: Import photo cache (version 5+)
            var importedCacheCount = 0
            if let photoCacheEntries = backup.photoCache {
                for cacheEntry in photoCacheEntries {
                    guard let uuid = UUID(uuidString: cacheEntry.id) else {
                        debugLog("⚠️ Skipping cache entry with invalid UUID: \(cacheEntry.id)")
                        continue
                    }

                    let newCache = PhotoRegionCache(context: context)
                    newCache.id = uuid
                    newCache.photoLocalIdentifier = cacheEntry.photoLocalIdentifier
                    newCache.photoCloudIdentifier = cacheEntry.photoCloudIdentifier
                    newCache.photoDate = cacheEntry.photoDate
                    newCache.photoLatitude = cacheEntry.photoLatitude
                    newCache.photoLongitude = cacheEntry.photoLongitude
                    newCache.regionCode = cacheEntry.regionCode
                    newCache.processedDate = cacheEntry.processedDate
                    importedCacheCount += 1
                }
                debugLog("📸 Restored \(importedCacheCount) photo cache entries")
            }

            // PHASE 8: Save to Core Data
            do {
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                // Restore settings on failure
                debugLog("❌ Failed to save imported data: \(error.localizedDescription)")
                debugLog("🔄 Restoring previous settings...")
                settingsManager.homeCoordinate = previousHomeCoordinate
                settingsManager.homeLocationName = previousHomeLocationName
                settingsManager.homeAddress = previousHomeAddress
                settingsManager.notifyOnMonthlyRecords = previousNotifyMonthly
                settingsManager.notifyOnYearlyRecords = previousNotifyYearly
                settingsManager.notifyOnAllTimeRecords = previousNotifyAllTime
                settingsManager.notifyOnNewRegion = previousNotifyNewRegion
                settingsManager.photoPromptsEnabled = previousPhotoPrompts
                settingsManager.inactivityReminderEnabled = previousInactivityReminder
                settingsManager.inactivityReminderDays = previousInactivityReminderDays
                settingsManager.summaryNotificationsEnabled = previousSummaryNotifications
                settingsManager.unitSystem = previousUnitSystem
                settingsManager.minLatitudeDelta = previousMinLatDelta
                settingsManager.minLongitudeDelta = previousMinLonDelta
                settingsManager.minAltitudeDeltaMetersImperial = previousMinAltImperial
                settingsManager.minDistanceDeltaMetersImperial = previousMinDistImperial
                settingsManager.minAltitudeDeltaMetersMetric = previousMinAltMetric
                settingsManager.minDistanceDeltaMetersMetric = previousMinDistMetric
                settingsManager.saveSettings()
                return nil
            }

            // PHASE 9: Reload data into memory
            RecordManager.shared.loadRecordsFromHistory()
            RegionTrackingManager.shared.loadVisitedRegions()

            // Clean up any duplicates or at-home records that may have been imported
            let cleaned = RecordHistoryManager.shared.performDataCleanup()
            if cleaned > 0 {
                debugLog("🧹 Post-backup-import cleanup: cleaned \(cleaned) record(s)")
            }

            // Clean up old daily records (daily records are now stored in RecordHistoryEntry)
            // Old daily records from previous months will be cleaned up automatically
            RecordHistoryManager.shared.cleanupOldDailyRecords()

            // PHASE 10: Request photo library access if backup contains photos
            let recordsWithPhotos = recordsToImport.filter { $0.detail.photoAssetIdentifier != nil }.count
            if recordsWithPhotos > 0 {
                debugLog("📸 Backup contains \(recordsWithPhotos) records with photos - checking photo library access...")
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

                if status == .notDetermined {
                    debugLog("📸 Requesting photo library access...")
                    let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    debugLog("📸 Photo library access: \(newStatus.rawValue)")

                    // If still not authorized after request, show alert
                    if newStatus != .authorized && newStatus != .limited {
                        await showPhotoAccessAlert(recordCount: recordsWithPhotos)
                    }
                } else if status == .authorized || status == .limited {
                    debugLog("📸 Photo library access already granted")
                } else {
                    debugLog("⚠️ Photo library access denied - photos in backup will not be accessible")
                    // Show alert directing user to Settings
                    await showPhotoAccessAlert(recordCount: recordsWithPhotos)
                }
            }

            // PHASE 11: Generate thumbnails for restored records with photos
            debugLog("📸 Generating thumbnails for restored records...")
            await ThumbnailCache.shared.generateMissingThumbnails()

            // PHASE 12: Trigger CloudKit sync
            do {
                if context.hasChanges {
                    try context.save()
                    debugLog("☁️ Saved context with imported records and regions")
                }

                // Give CloudKit a moment to pick up the changes
                try await Task.sleep(nanoseconds: mediumPauseNanos)

                // Trigger CloudKit to notice the new records
                context.refreshAllObjects()

                debugLog("☁️ Triggered CloudKit export - watch for 'Export started' in logs")
            } catch {
                debugLog("⚠️ Error triggering sync: \(error.localizedDescription)")
            }

            debugLog("✅ Backup imported: \(importedRecordCount) records, \(importedRegionCount) new regions processed, \(importedCacheCount) photo cache entries, \(failedRecordCount) failed")
            debugLog("☁️ IMPORTANT: Wait for 'Export completed' in logs before deleting app!")

            // Backup restore is a completed data path — release the restore gate
            SettingsManager.shared.needsDataRestore = false

            return (records: importedRecordCount, regions: importedRegionCount, cache: importedCacheCount, failed: failedRecordCount)

        } catch {
            debugLog("❌ Backup import failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Photo Access Alert

    /// Show alert when photo access is needed but not granted
    private func showPhotoAccessAlert(recordCount: Int) async {
        let alert = UIAlertController(
            title: "Photo Access Required",
            message: "Your backup includes \(recordCount) records with photos. To view these photos, please grant photo library access in Settings → Privacy & Security → Photos → GeoRecords.",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })

        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))

        // Present on the root view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(alert, animated: true)
        }
    }

    // MARK: - Backup Info

    /// Get information about a backup file without importing it
    /// - Parameter url: URL to the backup JSON file
    /// - Returns: Tuple with counts and metadata, or nil if file is invalid
    func getBackupInfo(from url: URL) -> (recordCount: Int, regionCount: Int, exportDate: Date, deviceName: String)? {
        do {
            let jsonData = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let backup = try decoder.decode(BackupFile.self, from: jsonData)
            return (backup.recordCount, backup.visitedRegionCount ?? 0, backup.exportDate, backup.deviceName)
        } catch {
            debugLog("❌ Could not read backup info: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - CLLocationCoordinate2D Import

import CoreLocation
