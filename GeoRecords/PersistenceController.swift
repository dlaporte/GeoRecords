@preconcurrency import CoreData
import SwiftUI
@preconcurrency import CloudKit

@MainActor
class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    var loadError: Error?

    @Published var showDatabaseRecoveryAlert = false
    @Published var databaseWasDeleted = false
    @Published var isSyncing = false

    /// Changes whenever the persistent store is destroyed and rebuilt (Delete All
    /// Records, database recovery). The root tab hierarchy is keyed on this so
    /// SwiftUI rebuilds every view — @FetchRequest results and any held
    /// NSManagedObjects from the OLD store are torn down instead of crashing with
    /// "persistent store is not reachable from this NSManagedObjectContext's
    /// coordinator" on next render.
    @Published private(set) var storeGeneration = UUID()

    /// Call on the main thread after a successful store destroy + reload
    func noteStoreReplaced() {
        storeGeneration = UUID()
        debugLog("♻️ Persistent store replaced - invalidating all fetched objects")
    }
    @Published var lastSyncError: Error?
    @Published var lastExportTime: Date?
    @Published var lastImportTime: Date?
    @Published var pendingExport = false

    init() {
        container = NSPersistentCloudKitContainer(name: "GeoRecordsModel")

        // Use App Group container for widget data sharing
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.georecords.shared") {
            let storeURL = appGroupURL.appendingPathComponent("GeoRecordsModel.sqlite")
            let storeDescription = NSPersistentStoreDescription(url: storeURL)

            // Enable CloudKit sync
            storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.georecords"
            )

            // Enable persistent history tracking (required for CloudKit)
            storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            container.persistentStoreDescriptions = [storeDescription]
        } else {
            // Fallback: Enable CloudKit on default store
            if let storeDescription = container.persistentStoreDescriptions.first {
                storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: "iCloud.com.georecords"
                )
                storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            }
        }

        // Automatically merge changes from CloudKit
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        container.loadPersistentStores { [weak self] storeDescription, error in
            guard let self = self else { return }

            if let error = error as NSError? {
                // Log the error for debugging
                debugLog("⚠️ Core Data error: \(error), \(error.userInfo)")
                self.loadError = error

                // Check if this is a CloudKit schema error (134060)
                if error.code == 134060 {
                    debugLog("☁️ CloudKit schema error detected - incompatible database schema")
                    debugLog("☁️ This usually means the app was updated and needs a fresh database")

                    // Automatically attempt recovery for schema errors
                    if let storeURL = storeDescription.url {
                        debugLog("☁️ Automatically removing old database to fix schema error")
                        self.attemptDatabaseRecovery(storeURL: storeURL)
                        return
                    }
                }

                // For other errors, show alert and let user decide
                Task { @MainActor in
                    self.showDatabaseRecoveryAlert = true
                }
            } else {
                debugLog("Persistent store loaded: \(storeDescription.url?.absoluteString ?? "")")
            }
        }

        // Monitor CloudKit sync events
        setupCloudKitNotifications()
    }

    private func setupCloudKitNotifications() {
        // Listen for CloudKit import/export events
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else {
                return
            }

            Task { @MainActor in
                self.handleCloudKitEvent(event)
            }
        }
    }

    private func handleCloudKitEvent(_ event: NSPersistentCloudKitContainer.Event) {
        switch event.type {
        case .setup:
            debugLog("☁️ CloudKit: Setup \(event.endDate != nil ? "completed" : "started")")
        case .import:
            if event.endDate != nil {
                debugLog("☁️ CloudKit: Import completed ✅")
                isSyncing = false
                lastImportTime = Date()
            } else {
                debugLog("☁️ CloudKit: Import started...")
                isSyncing = true
            }
        case .export:
            if event.endDate != nil {
                debugLog("☁️ CloudKit: Export completed ✅ - Data is now in iCloud!")
                isSyncing = false
                lastExportTime = Date()
                pendingExport = false
            } else {
                debugLog("☁️ CloudKit: Export started...")
                isSyncing = true
                pendingExport = true
            }
        @unknown default:
            break
        }

        // Handle errors
        if let error = event.error {
            debugLog("☁️ CloudKit error: \(error.localizedDescription)")
            lastSyncError = error
        }
    }

    func attemptDatabaseRecovery(storeURL: URL) {
        debugLog("User approved database recovery. Setting aside corrupted store at: \(storeURL)")

        // Move the corrupted store ASIDE instead of deleting it: if the user's recent
        // records had not yet exported to CloudKit, the set-aside file is the only
        // remaining copy and may be recoverable with support
        let timestamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: storeURL.path + "-corrupt-\(timestamp)" + suffix)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                debugLog("✅ Set aside corrupted database file: \(destination.lastPathComponent)")
            } catch {
                debugLog("⚠️ Failed to set aside \(source.lastPathComponent): \(error.localizedDescription) - deleting instead")
                try? FileManager.default.removeItem(at: source)
            }
        }

        // Create backup file to indicate deletion happened
        let backupMarker = storeURL.deletingLastPathComponent().appendingPathComponent("database_was_reset.txt")
        do {
            try "Database was reset on \(Date())".write(to: backupMarker, atomically: true, encoding: .utf8)
            debugLog("✅ Created database reset marker file")
        } catch {
            debugLog("⚠️ Failed to create reset marker file: \(error.localizedDescription)")
            // Non-critical, continue with recovery
        }

        // Retry loading
        container.loadPersistentStores { [weak self] retryDescription, retryError in
            guard let self = self else { return }

            if let retryError = retryError {
                debugLog("❌ Failed to recover Core Data: \(retryError)")
                self.loadError = retryError
                debugLog("FATAL: Core Data store is permanently broken. User data operations will fail.")
            } else {
                debugLog("✅ Successfully recovered Core Data store")
                self.loadError = nil
                Task { @MainActor in
                    self.databaseWasDeleted = true
                    self.noteStoreReplaced()
                }
            }
        }
    }

    /// Check if there was a load error and show alert if needed
    func showErrorIfNeeded() -> Alert? {
        guard let error = loadError else { return nil }
        return Alert(
            title: Text("Database Error"),
            message: Text("The app encountered a problem with its database. Your data may have been reset. Error: \(error.localizedDescription)"),
            dismissButton: .default(Text("OK"))
        )
    }

    /// Check if there's existing data in CloudKit (indicates restore from another device)
    func hasExistingCloudData() async -> Bool {
        let context = container.viewContext
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.fetchLimit = 1

        do {
            let count = try await context.perform {
                try context.count(for: request)
            }
            debugLog("☁️ Found \(count) record(s) in local database")
            return count > 0
        } catch {
            debugLog("☁️ Error checking for existing data: \(error)")
            return false
        }
    }

    /// Check if CloudKit has any actual records for this app
    /// This checks if the CloudKit zone exists, then waits for sync to complete and checks local data
    func hasExistingCloudDataThrowing() async throws -> Bool {
        debugLog("☁️ Checking for iCloud data...")

        // Check iCloud account status first
        let accountStatus = await checkCloudKitAccountStatus()
        debugLog("☁️ CloudKit account status: \(accountStatus)")

        guard accountStatus == "available" else {
            debugLog("☁️ iCloud not available (status: \(accountStatus)), skipping cloud check")
            return false
        }

        let ckContainer = CKContainer(identifier: "iCloud.com.georecords")
        let database = ckContainer.privateCloudDatabase

        // Check if the Core Data zone exists
        let allZones: [CKRecordZone]
        do {
            allZones = try await database.allRecordZones()
        } catch {
            debugLog("☁️ Error fetching CloudKit zones: \(error.localizedDescription)")
            return false
        }

        let dataZone = allZones.first { $0.zoneID.zoneName == "com.apple.coredata.cloudkit.zone" }

        guard dataZone != nil else {
            debugLog("☁️ No CloudKit zone found - this is a new user")
            return false
        }

        // The zone existing is our answer: this account has synced data before, so
        // attempt a restore. Do NOT wait here for the local import as proof — a full
        // re-import after a store wipe takes minutes, and mirroring briefly reports
        // isSyncing=false right after a store reload, so any short local-data wait
        // gives up long before real data can arrive (the old 15s loop bailed at ~5s
        // and sent post-delete users to "No Records Found" with a full zone in iCloud).
        // Whether the data actually ARRIVES is the restore flow's job:
        // monitorSyncCompletion waits up to 120s with progress UI, and an empty zone
        // (rare: everything previously deleted) simply falls through to the
        // no-records prompt there instead.
        // (Direct CKQuery for record counts isn't possible: CD_ record types aren't
        // queryable — "recordName not queryable".)
        debugLog("☁️ CloudKit zone exists - user has data to restore")
        return true
    }

    /// Check CloudKit account status
    private func checkCloudKitAccountStatus() async -> String {
        do {
            let status = try await CKContainer(identifier: "iCloud.com.georecords").accountStatus()
            switch status {
            case .available:
                return "available"
            case .noAccount:
                return "noAccount"
            case .restricted:
                return "restricted"
            case .couldNotDetermine:
                return "couldNotDetermine"
            case .temporarilyUnavailable:
                return "temporarilyUnavailable"
            @unknown default:
                return "unknown"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    /// Completely delete the CloudKit zone and all data in iCloud
    /// This is a destructive operation that removes ALL synced data from iCloud
    /// - Returns: true if successful, false otherwise
    func deleteCloudKitZone() async -> Bool {
        debugLog("☁️ Deleting CloudKit zone...")

        let ckContainer = CKContainer(identifier: "iCloud.com.georecords")
        let database = ckContainer.privateCloudDatabase

        // The Core Data CloudKit zone ID
        let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)

        do {
            // Delete the entire zone - this removes all records in it
            try await database.deleteRecordZone(withID: zoneID)
            debugLog("☁️ Successfully deleted CloudKit zone - all iCloud data removed")
            return true
        } catch {
            // CKError.zoneNotFound means it's already gone, which is fine
            if let ckError = error as? CKError, ckError.code == .zoneNotFound {
                debugLog("☁️ CloudKit zone not found (already deleted or never created)")
                return true
            }
            debugLog("☁️ Error deleting CloudKit zone: \(error.localizedDescription)")
            return false
        }
    }

}
