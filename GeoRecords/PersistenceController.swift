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
        debugLog("User approved database recovery. Removing corrupted store at: \(storeURL)")

        // Remove corrupted store with explicit error handling
        do {
            try FileManager.default.removeItem(at: storeURL)
            debugLog("✅ Successfully removed corrupted database file")
        } catch {
            debugLog("⚠️ Failed to remove corrupted database: \(error.localizedDescription)")
            // Continue anyway - the store might not exist or might be removed on retry
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

    /// Quick check if CloudKit has any data for this app (checks zone existence, not record download)
    /// This is fast (~2 seconds) and doesn't wait for full sync
    func hasExistingCloudDataThrowing() async throws -> Bool {
        debugLog("☁️ Quick check for iCloud data (checking zone existence)...")

        // Check iCloud account status first
        let accountStatus = await checkCloudKitAccountStatus()
        debugLog("☁️ CloudKit account status: \(accountStatus)")

        guard accountStatus == "available" else {
            debugLog("☁️ iCloud not available, skipping cloud check")
            return false
        }

        // Quick check: Does the Core Data CloudKit zone exist?
        // If yes, user has synced data before - prompt to restore
        let ckContainer = CKContainer(identifier: "iCloud.com.georecords")
        let database = ckContainer.privateCloudDatabase

        do {
            let allZones = try await database.allRecordZones()
            let hasDataZone = allZones.contains { $0.zoneID.zoneName == "com.apple.coredata.cloudkit.zone" }

            if hasDataZone {
                debugLog("☁️ CloudKit zone exists - user has iCloud data!")
                return true
            } else {
                debugLog("☁️ No CloudKit zone found - this is a new user")
                return false
            }
        } catch {
            debugLog("☁️ Error checking CloudKit zones: \(error.localizedDescription)")
            // On error, also check if we have local data (might have synced already)
            let context = container.viewContext
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.fetchLimit = 1
            let count = try await context.perform { try context.count(for: request) }
            return count > 0
        }
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

}
