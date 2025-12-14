import Foundation
import CoreData
import CoreLocation

/// Background geocoder that progressively fills in missing location names for records
/// Runs in background with rate limiting to avoid hitting Apple's geocoding limits
@MainActor
class BackgroundGeocoder {
    static let shared = BackgroundGeocoder()

    private var isRunning = false
    private let geocoder = CLGeocoder()

    private var context: NSManagedObjectContext {
        PersistenceController.shared.container.viewContext
    }

    /// Start geocoding records that are missing location names
    /// Runs in background, rate-limited to ~40 requests/minute
    func geocodeMissingLocations() async {
        // Prevent multiple concurrent runs
        guard !isRunning else {
            debugLog("📍 Background geocoder already running, skipping")
            return
        }

        isRunning = true
        debugLog("📍 Starting background geocoding of missing locations...")

        var geocodedCount = 0
        var errorCount = 0

        while true {
            // Fetch next batch of records without location names
            let records = fetchRecordsWithoutLocationName(limit: 10)

            if records.isEmpty {
                debugLog("📍 Background geocoding complete: \(geocodedCount) locations resolved, \(errorCount) errors")
                break
            }

            for record in records {
                let coordinate = CLLocationCoordinate2D(latitude: record.latitude, longitude: record.longitude)

                // 1. Check in-memory cache first
                if let cachedName = await sharedGeocodingCache.getCachedName(for: coordinate) {
                    updateRecordLocationName(record: record, locationName: cachedName)
                    geocodedCount += 1
                    continue
                }

                // 2. Check database for existing record with location name nearby
                if let existingName = await MainActor.run(body: {
                    RecordHistoryManager.shared.lookupLocationName(latitude: record.latitude, longitude: record.longitude)
                }) {
                    await sharedGeocodingCache.setCachedName(existingName, for: coordinate)
                    updateRecordLocationName(record: record, locationName: existingName)
                    geocodedCount += 1
                    continue
                }

                // 3. Fall back to Apple geocoder (rate limited)
                // Rate limit: wait 1.5 seconds between API requests (~40/minute)
                if geocodedCount > 0 || errorCount > 0 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }

                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                do {
                    let placemarks = try await geocoder.reverseGeocodeLocation(location)
                    if let placemark = placemarks.first {
                        let name = FormatUtils.formatPlacemarkName(placemark)
                        await sharedGeocodingCache.setCachedName(name, for: coordinate)
                        updateRecordLocationName(record: record, locationName: name)
                        geocodedCount += 1
                    }
                } catch {
                    errorCount += 1
                    // Don't log every error, just continue
                    if errorCount <= 5 {
                        debugLog("📍 Geocoding error: \(error.localizedDescription)")
                    }
                }

                // Log progress periodically
                if (geocodedCount + errorCount) % 25 == 0 {
                    debugLog("📍 Background geocoding progress: \(geocodedCount) resolved, \(errorCount) errors")
                }
            }
        }

        isRunning = false
    }

    /// Fetch records that don't have a location name yet
    private func fetchRecordsWithoutLocationName(limit: Int) -> [RecordHistoryEntry] {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "locationName == nil OR locationName == %@", "")
        request.fetchLimit = limit
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]  // Newest first

        do {
            return try context.fetch(request)
        } catch {
            debugLog("📍 Error fetching records for geocoding: \(error.localizedDescription)")
            return []
        }
    }

    /// Update a record with its geocoded location name
    private func updateRecordLocationName(record: RecordHistoryEntry, locationName: String) {
        // Check if record was deleted while we were geocoding
        guard !record.isDeleted, record.managedObjectContext != nil else {
            return
        }

        record.locationName = locationName
        do {
            try context.save()
        } catch {
            debugLog("📍 Error saving location name: \(error.localizedDescription)")
        }
    }

    /// Check if there are records that need geocoding
    func hasPendingGeocoding() -> Bool {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "locationName == nil OR locationName == %@", "")
        request.fetchLimit = 1

        do {
            let count = try context.count(for: request)
            return count > 0
        } catch {
            return false
        }
    }

    /// Get count of records still needing geocoding
    func pendingGeocodingCount() -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "locationName == nil OR locationName == %@", "")

        do {
            return try context.count(for: request)
        } catch {
            return 0
        }
    }
}
