import CoreData

struct PersistenceController {
    static let shared = PersistenceController()
    
    let container: NSPersistentContainer
    
    init() {
        // Replace "GeoRecordsModel" with the actual name of your .xcdatamodeld file
        container = NSPersistentContainer(name: "GeoRecordsModel")
        
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                // In a production app, handle the error gracefully
                fatalError("Unresolved error \(error), \(error.userInfo)")
            } else {
                print("Persistent store loaded: \(storeDescription.url?.absoluteString ?? "")")
            }
        }
    }
}
