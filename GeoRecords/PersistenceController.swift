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
            debugLog("☁️ CloudKit: Setup started")
        case .import:
            if event.endDate != nil {
                debugLog("☁️ CloudKit: Import completed")
                isSyncing = false
            } else {
                debugLog("☁️ CloudKit: Import started")
                isSyncing = true
            }
        case .export:
            if event.endDate != nil {
                debugLog("☁️ CloudKit: Export completed")
                isSyncing = false
            } else {
                debugLog("☁️ CloudKit: Export started")
                isSyncing = true
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

    /// Throwing version of hasExistingCloudData for proper error handling
    /// Waits for initial CloudKit sync to complete before checking
    func hasExistingCloudDataThrowing() async throws -> Bool {
        // Wait for CloudKit to complete initial import (up to 15 seconds)
        let maxWaitTime: TimeInterval = 15.0
        let checkInterval: TimeInterval = 0.3
        var waitedTime: TimeInterval = 0
        var syncStarted = false

        // Wait for sync to start and then complete
        while waitedTime < maxWaitTime {
            let currentlySyncing = await MainActor.run(body: { self.isSyncing })

            if currentlySyncing {
                syncStarted = true
                debugLog("☁️ Waiting for CloudKit sync to complete...")
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                waitedTime += checkInterval
                continue
            }

            // Sync finished (or not started yet) - check if we have data
            let context = container.viewContext
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.fetchLimit = 1

            let count = try await context.perform {
                try context.count(for: request)
            }
            debugLog("☁️ Found \(count) record(s) in local database (after \(String(format: "%.1f", waitedTime))s)")

            if count > 0 {
                return true
            }

            // If sync already started and completed with no data, we're done
            if syncStarted {
                debugLog("☁️ CloudKit sync completed but no data found")
                return false
            }

            // No data yet and sync hasn't started - wait a bit more
            if waitedTime < maxWaitTime {
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                waitedTime += checkInterval
            }
        }

        debugLog("☁️ No data found after waiting \(maxWaitTime)s for CloudKit sync")
        return false
    }
}
