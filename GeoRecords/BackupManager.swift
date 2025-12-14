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
        let notes: String?
    }

    /// The complete backup file structure
    struct BackupFile: Codable {
        let version: Int
        let exportDate: Date
        let appVersion: String
        let deviceName: String
        let recordCount: Int
        let records: [BackupRecord]
    }

    // MARK: - Export

    /// Export all records to a JSON backup file
    /// - Returns: URL to the temporary backup file, or nil if export failed
    func exportBackup() async -> URL? {
        let context = PersistenceController.shared.container.viewContext

        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        do {
            let entries = try context.fetch(request)

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
                    notes: entry.notes
                )
            }

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            let deviceName = UIDevice.current.name

            let backup = BackupFile(
                version: 1,
                exportDate: Date(),
                appVersion: appVersion,
                deviceName: deviceName,
                recordCount: backupRecords.count,
                records: backupRecords
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

            debugLog("✅ Backup exported: \(backupRecords.count) records to \(fileName)")
            return tempURL

        } catch {
            debugLog("❌ Backup export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Import

    /// Import records from a backup file
    /// - Parameter url: URL to the backup JSON file
    /// - Returns: Number of records imported, or nil if import failed
    func importBackup(from url: URL) async -> Int? {
        do {
            // Read and parse JSON
            let jsonData = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let backup = try decoder.decode(BackupFile.self, from: jsonData)

            debugLog("📥 Importing backup: version \(backup.version), \(backup.recordCount) records from \(backup.deviceName)")

            // Validate version
            guard backup.version == 1 else {
                debugLog("❌ Unsupported backup version: \(backup.version)")
                return nil
            }

            var importedCount = 0

            for record in backup.records {
                // Create RecordDetail from backup record
                guard let uuid = UUID(uuidString: record.id) else { continue }

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
                    notes: record.notes
                )

                // Add to database (duplicate detection will prevent re-adding existing records)
                RecordHistoryManager.shared.addRecord(recordType: record.recordType, detail: detail)
                importedCount += 1
            }

            // Reload records into memory
            RecordManager.shared.loadRecordsFromHistory()

            // Regenerate daily statistics for graphs
            DailyStatisticManager.shared.regenerateAllStatistics()

            debugLog("✅ Backup imported: \(importedCount) records processed")
            return importedCount

        } catch {
            debugLog("❌ Backup import failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Backup Info

    /// Get information about a backup file without importing it
    /// - Parameter url: URL to the backup JSON file
    /// - Returns: Tuple with record count and export date, or nil if file is invalid
    func getBackupInfo(from url: URL) -> (recordCount: Int, exportDate: Date, deviceName: String)? {
        do {
            let jsonData = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let backup = try decoder.decode(BackupFile.self, from: jsonData)
            return (backup.recordCount, backup.exportDate, backup.deviceName)
        } catch {
            debugLog("❌ Could not read backup info: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - CLLocationCoordinate2D Import

import CoreLocation
