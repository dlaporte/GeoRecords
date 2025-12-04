import CoreData
import SwiftUI

@MainActor
class RecordHistoryManager: ObservableObject {
    static let shared = RecordHistoryManager()

    @Published var errorMessage: String?
    @Published var showError: Bool = false

    private var context: NSManagedObjectContext {
        assert(Thread.isMainThread, "Core Data viewContext must be accessed from main thread")
        return PersistenceController.shared.container.viewContext
    }

    func addRecord(recordType: String, detail: RecordDetail) {
        let newEntry = RecordHistoryEntry(context: context)
        newEntry.id = detail.id
        newEntry.timestamp = detail.timestamp  // timestamp is non-optional Date
        newEntry.recordType = recordType
        newEntry.value = detail.value
        newEntry.latitude = detail.coordinate.latitude
        newEntry.longitude = detail.coordinate.longitude
        newEntry.altitude = detail.altitude
        newEntry.locationName = detail.locationName
        newEntry.photoData = detail.photoData

        do {
            try context.save()
            debugLog("Record saved: \(recordType) with value: \(detail.value)")
        } catch {
            let message = "Failed to save record: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
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

    func clearHistory() {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = RecordHistoryEntry.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        deleteRequest.resultType = .resultTypeObjectIDs

        do {
            if let result = try context.execute(deleteRequest) as? NSBatchDeleteResult,
               let objectIDs = result.result as? [NSManagedObjectID] {
                let changes = [NSDeletedObjectsKey: objectIDs]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
            }
            try context.save()
            debugLog("History cleared.")

            // Also reset in-memory records so that Records screen updates.
            RecordManager.shared.resetRecords()
        } catch {
            let message = "Failed to clear history: \(error.localizedDescription)"
            debugLog(message)
            showErrorAlert(message)
        }
    }
}
