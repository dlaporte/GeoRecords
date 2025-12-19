import Foundation
import CoreData
import UIKit

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
        let notifyOnMonthlyRecords: Bool
        let notifyOnYearlyRecords: Bool
        let notifyOnAllTimeRecords: Bool
        let photoPromptsEnabled: Bool
        let inactivityReminderEnabled: Bool
        let summaryNotificationsEnabled: Bool
        let unitSystem: String  // "metric" or "imperial"
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

        do {
            let entries = try context.fetch(recordRequest)
            let regions = try context.fetch(regionRequest)

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
                    notes: entry.notes
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

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            let deviceName = UIDevice.current.name

            // Export settings
            let settingsManager = SettingsManager.shared
            let backupSettings = BackupSettings(
                homeLatitude: settingsManager.homeCoordinate?.latitude,
                homeLongitude: settingsManager.homeCoordinate?.longitude,
                homeLocationName: settingsManager.homeLocationName,
                notifyOnMonthlyRecords: settingsManager.notifyOnMonthlyRecords,
                notifyOnYearlyRecords: settingsManager.notifyOnYearlyRecords,
                notifyOnAllTimeRecords: settingsManager.notifyOnAllTimeRecords,
                photoPromptsEnabled: settingsManager.photoPromptsEnabled,
                inactivityReminderEnabled: settingsManager.inactivityReminderEnabled,
                summaryNotificationsEnabled: settingsManager.summaryNotificationsEnabled,
                unitSystem: settingsManager.unitSystem.rawValue
            )

            let backup = BackupFile(
                version: 3,  // Updated version to include settings
                exportDate: Date(),
                appVersion: appVersion,
                deviceName: deviceName,
                recordCount: backupRecords.count,
                records: backupRecords,
                visitedRegionCount: backupRegions.count,
                visitedRegions: backupRegions,
                settings: backupSettings
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

            debugLog("✅ Backup exported: \(backupRecords.count) records, \(backupRegions.count) visited regions to \(fileName)")
            return tempURL

        } catch {
            debugLog("❌ Backup export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Import

    /// Import records from a backup file (replaces all existing data)
    /// Uses transaction-safe approach: validates all data first, creates rollback point, then imports
    /// - Parameter url: URL to the backup JSON file
    /// - Returns: Tuple with (records imported, regions imported), or nil if import failed
    func importBackup(from url: URL) async -> (records: Int, regions: Int)? {
        do {
            // PHASE 1: Parse and validate backup file BEFORE any destructive operations
            let jsonData = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let backup = try decoder.decode(BackupFile.self, from: jsonData)

            let regionCount = backup.visitedRegionCount ?? 0
            debugLog("📥 Importing backup: version \(backup.version), \(backup.recordCount) records, \(regionCount) visited regions from \(backup.deviceName)")

            // Validate version (support v1, v2, and v3)
            guard backup.version >= 1 && backup.version <= 3 else {
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
                    notes: record.notes
                )
                recordsToImport.append((record.recordType, detail))
            }

            // Validate regions
            var regionsToImport: [BackupVisitedRegion] = []
            if let visitedRegions = backup.visitedRegions {
                for region in visitedRegions {
                    guard !region.regionCode.isEmpty, !region.regionName.isEmpty else {
                        debugLog("⚠️ Skipping region with empty code or name")
                        continue
                    }
                    regionsToImport.append(region)
                }
            }

            debugLog("✓ Validation passed: \(recordsToImport.count) records, \(regionsToImport.count) regions ready to import")

            // PHASE 3: Create rollback point by saving current settings
            let settingsManager = SettingsManager.shared
            let previousHomeCoordinate = settingsManager.homeCoordinate
            let previousHomeLocationName = settingsManager.homeLocationName
            let previousNotifyMonthly = settingsManager.notifyOnMonthlyRecords
            let previousNotifyYearly = settingsManager.notifyOnYearlyRecords
            let previousNotifyAllTime = settingsManager.notifyOnAllTimeRecords
            let previousPhotoPrompts = settingsManager.photoPromptsEnabled
            let previousInactivityReminder = settingsManager.inactivityReminderEnabled
            let previousSummaryNotifications = settingsManager.summaryNotificationsEnabled
            let previousUnitSystem = settingsManager.unitSystem

            // PHASE 4: Clear existing data (point of no return for data, but settings can be restored)
            debugLog("🗑️ Clearing existing data before restore...")
            RecordHistoryManager.shared.clearHistory()

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

                // Restore notification settings
                settingsManager.notifyOnMonthlyRecords = backupSettings.notifyOnMonthlyRecords
                settingsManager.notifyOnYearlyRecords = backupSettings.notifyOnYearlyRecords
                settingsManager.notifyOnAllTimeRecords = backupSettings.notifyOnAllTimeRecords
                settingsManager.photoPromptsEnabled = backupSettings.photoPromptsEnabled
                settingsManager.inactivityReminderEnabled = backupSettings.inactivityReminderEnabled
                settingsManager.summaryNotificationsEnabled = backupSettings.summaryNotificationsEnabled

                // Restore unit system
                if let unitSystem = UnitSystem(rawValue: backupSettings.unitSystem) {
                    settingsManager.unitSystem = unitSystem
                }

                settingsManager.saveSettings()
                debugLog("⚙️ Settings restored from backup")
            }

            // PHASE 6: Import all validated records
            var importedRecordCount = 0
            let context = PersistenceController.shared.container.viewContext

            for (recordType, detail) in recordsToImport {
                RecordHistoryManager.shared.addRecord(recordType: recordType, detail: detail)
                importedRecordCount += 1
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
                settingsManager.notifyOnMonthlyRecords = previousNotifyMonthly
                settingsManager.notifyOnYearlyRecords = previousNotifyYearly
                settingsManager.notifyOnAllTimeRecords = previousNotifyAllTime
                settingsManager.photoPromptsEnabled = previousPhotoPrompts
                settingsManager.inactivityReminderEnabled = previousInactivityReminder
                settingsManager.summaryNotificationsEnabled = previousSummaryNotifications
                settingsManager.unitSystem = previousUnitSystem
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

            // Regenerate daily statistics for graphs
            DailyStatisticManager.shared.regenerateAllStatistics()

            // PHASE 10: Trigger CloudKit sync
            do {
                if context.hasChanges {
                    try context.save()
                    debugLog("☁️ Saved context with imported records and regions")
                }

                // Give CloudKit a moment to pick up the changes
                try await Task.sleep(nanoseconds: 500_000_000)

                // Trigger CloudKit to notice the new records
                context.refreshAllObjects()

                debugLog("☁️ Triggered CloudKit export - watch for 'Export started' in logs")
            } catch {
                debugLog("⚠️ Error triggering sync: \(error.localizedDescription)")
            }

            debugLog("✅ Backup imported: \(importedRecordCount) records, \(importedRegionCount) new regions processed")
            debugLog("☁️ IMPORTANT: Wait for 'Export completed' in logs before deleting app!")
            return (records: importedRecordCount, regions: importedRegionCount)

        } catch {
            debugLog("❌ Backup import failed: \(error.localizedDescription)")
            return nil
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
