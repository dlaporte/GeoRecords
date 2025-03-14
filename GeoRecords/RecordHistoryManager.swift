import CoreData

class RecordHistoryManager {
    static let shared = RecordHistoryManager()
    let context = PersistenceController.shared.container.viewContext
    
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
        
        do {
            try context.save()
            print("Record saved: \(recordType) with value: \(detail.value)")
        } catch {
            print("Failed to save record history: \(error.localizedDescription)")
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
            print("History cleared.")
            
            // Also reset in-memory records so that Records screen updates.
            RecordManager.shared.resetRecords()
        } catch {
            print("Failed to clear history: \(error.localizedDescription)")
        }
    }
}
