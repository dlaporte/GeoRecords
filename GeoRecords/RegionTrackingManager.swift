import Foundation
import CoreLocation
import Photos
import CoreData
import UserNotifications

// MARK: - Discovered Region (for confirmation UI)

/// A region discovered during photo scanning, pending user confirmation
struct DiscoveredRegion: Identifiable {
    let id = UUID()
    let regionCode: String
    let regionName: String
    let regionType: RegionType
    let continent: Continent?
    var photoAssets: [PHAsset]
    var confirmed: Bool = true  // Default to selected
    var selectedPhotoIndex: Int = 0  // Index of photo selected in carousel

    var photoCount: Int { photoAssets.count }

    /// Get the currently selected photo asset
    var selectedAsset: PHAsset? {
        guard selectedPhotoIndex >= 0 && selectedPhotoIndex < photoAssets.count else {
            return photoAssets.first
        }
        return photoAssets[selectedPhotoIndex]
    }
}

// MARK: - Region Tracking Manager

/// Singleton manager for tracking visited regions
/// Coordinates visit recording from photos, location updates, and manual entries
@MainActor
class RegionTrackingManager: ObservableObject {
    static let shared = RegionTrackingManager()

    // MARK: - Published Properties

    @Published var visitedStates: [RecordDetail] = []
    @Published var visitedCountries: [RecordDetail] = []
    @Published var visitedContinents: [RecordDetail] = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: Double = 0

    // Statistics
    @Published var stateCount: Int = 0
    @Published var countryCount: Int = 0
    @Published var continentCount: Int = 0

    private let context: NSManagedObjectContext

    private init() {
        self.context = PersistenceController.shared.container.viewContext
        loadVisitedRegions()
    }

    // MARK: - Public API

    /// Record a visit to a region from coordinates
    /// - Parameters:
    ///   - coordinate: The location
    ///   - date: When the visit occurred
    ///   - source: How the visit was recorded (photo, location, manual)
    func recordVisit(coordinate: CLLocationCoordinate2D, date: Date, source: VisitSource, altitude: Double? = nil) {
        // Validate location
        let alt = altitude ?? 0
        switch validateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: alt) {
        case .nullIsland:
            debugLog("⚠️ RegionTrackingManager: Skipping Null Island location")
            return
        case .unrealisticAltitude(let meters):
            debugLog("⚠️ RegionTrackingManager: Skipping unrealistic altitude (\(Int(meters))m)")
            return
        case .valid:
            break
        }

        // Look up region
        guard let regionInfo = RegionLookupService.shared.region(for: coordinate) else {
            debugLog("📍 RegionTrackingManager: No region found for coordinate")
            return
        }

        // Record the visit
        addVisitToRegion(
            code: regionInfo.code,
            name: regionInfo.name,
            type: regionInfo.type,
            date: date,
            coordinate: coordinate,
            altitude: alt
        )

        debugLog("📍 RegionTrackingManager: Recorded visit to \(regionInfo.name) via \(source.rawValue)")
    }

    /// Record visits for confirmed regions (after user confirmation in wizard)
    /// - Parameter regions: The confirmed DiscoveredRegion objects
    func recordConfirmedRegions(_ regions: [DiscoveredRegion]) {
        for region in regions where region.confirmed {
            // Use the photo selected by the user in the carousel
            if let selectedAsset = region.selectedAsset,
               let location = selectedAsset.location,
               let date = selectedAsset.creationDate {
                // Get photo identifiers
                let localId = selectedAsset.localIdentifier
                let cloudId = PHPhotoLibrary.cloudIdentifier(for: selectedAsset)

                debugLog("📸 Recording region \(region.regionName) with photo localId: \(localId), cloudId: \(cloudId ?? "nil")")

                addVisitToRegion(
                    code: region.regionCode,
                    name: region.regionName,
                    type: region.regionType,
                    date: date,
                    coordinate: location.coordinate,
                    altitude: location.altitude,
                    photoAssetIdentifier: localId,
                    photoCloudIdentifier: cloudId,
                    suppressNotifications: true,  // Don't spam during photo scan
                    suppressPhotoPrompts: true    // Already came from photos
                )
            }
        }

        saveContext()
        loadVisitedRegions()
    }

    /// Check if a photo has already been processed for region tracking
    /// Uses 3-tier fallback matching: cloud ID → local ID → timestamp+location
    func isPhotoProcessed(asset: PHAsset) -> String? {
        // Get cloud identifier if available
        let cloudId = PHPhotoLibrary.cloudIdentifier(for: asset)

        // 1. Try cloud identifier match
        if let cloudId = cloudId {
            let request: NSFetchRequest<PhotoRegionCache> = PhotoRegionCache.fetchRequest()
            request.predicate = NSPredicate(format: "photoCloudIdentifier == %@", cloudId)
            request.fetchLimit = 1

            if let results = try? context.fetch(request), let cached = results.first {
                return cached.regionCode
            }
        }

        // 2. Try local identifier match
        let localRequest: NSFetchRequest<PhotoRegionCache> = PhotoRegionCache.fetchRequest()
        localRequest.predicate = NSPredicate(format: "photoLocalIdentifier == %@", asset.localIdentifier)
        localRequest.fetchLimit = 1

        if let results = try? context.fetch(localRequest), let cached = results.first {
            return cached.regionCode
        }

        // 3. Try timestamp + location fuzzy match
        if let location = asset.location, let date = asset.creationDate {
            let timeThreshold: TimeInterval = 2.0  // 2 seconds
            let startDate = date.addingTimeInterval(-timeThreshold)
            let endDate = date.addingTimeInterval(timeThreshold)

            let fuzzyRequest: NSFetchRequest<PhotoRegionCache> = PhotoRegionCache.fetchRequest()
            fuzzyRequest.predicate = NSPredicate(
                format: "photoDate >= %@ AND photoDate <= %@",
                startDate as NSDate,
                endDate as NSDate
            )

            if let results = try? context.fetch(fuzzyRequest) {
                let targetLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)

                for cached in results {
                    let cachedLocation = CLLocation(latitude: cached.photoLatitude, longitude: cached.photoLongitude)
                    if cachedLocation.distance(from: targetLocation) < regionTrackingDistanceThresholdMeters {
                        return cached.regionCode
                    }
                }
            }
        }

        return nil  // Not cached
    }

    /// Add a photo to the region cache after processing
    func cachePhotoRegion(asset: PHAsset, regionCode: String) {
        let cache = PhotoRegionCache(context: context)
        cache.id = UUID()
        cache.photoLocalIdentifier = asset.localIdentifier
        cache.photoCloudIdentifier = PHPhotoLibrary.cloudIdentifier(for: asset)
        cache.photoDate = asset.creationDate ?? Date()
        cache.photoLatitude = asset.location?.coordinate.latitude ?? 0
        cache.photoLongitude = asset.location?.coordinate.longitude ?? 0
        cache.regionCode = regionCode
        cache.processedDate = Date()

        saveContext()
    }

    /// Get visited continents (derived from continent records)
    func getVisitedContinents() -> Set<Continent> {
        var continents = Set<Continent>()

        for continentRecord in visitedContinents {
            if let continent = Continent(rawValue: continentRecord.locationName ?? "") {
                continents.insert(continent)
            }
        }

        return continents
    }

    /// Reload visited regions from Core Data (RecordHistoryEntry)
    func loadVisitedRegions() {
        // Query for state records
        let stateRequest: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        stateRequest.predicate = NSPredicate(format: "recordType == %@", RecordType.state.rawValue)
        stateRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        // Query for country records
        let countryRequest: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        countryRequest.predicate = NSPredicate(format: "recordType == %@", RecordType.country.rawValue)
        countryRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        // Query for continent records
        let continentRequest: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        continentRequest.predicate = NSPredicate(format: "recordType == %@", RecordType.continent.rawValue)
        continentRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            let stateEntries = try context.fetch(stateRequest)
            let countryEntries = try context.fetch(countryRequest)
            let continentEntries = try context.fetch(continentRequest)

            // Migrate any entries missing regionCode
            migrateRegionCodes(stateEntries: stateEntries, countryEntries: countryEntries, continentEntries: continentEntries)

            // Convert to RecordDetail and deduplicate by regionCode
            // (iCloud sync can create duplicates that bypass the addVisitToRegion check)
            visitedStates = deduplicateByRegionCode(stateEntries.compactMap { RecordDetail(from: $0) })
            visitedCountries = deduplicateByRegionCode(countryEntries.compactMap { RecordDetail(from: $0) })
            visitedContinents = deduplicateByRegionCode(continentEntries.compactMap { RecordDetail(from: $0) })

            // Count only the 50 actual states (exclude DC and territories) for the "X of 50" display
            let nonStateCodes = Set(["DC", "AS", "GU", "MP", "PR", "VI", "US-DC", "US-AS", "US-GU", "US-MP", "US-PR", "US-VI"])
            stateCount = visitedStates.filter { state in
                guard let code = state.regionCode else { return false }
                return !nonStateCodes.contains(code)
            }.count

            // Count only sovereign countries (exclude territories) for the "X of 195" display
            // Territories still appear as cards but don't count toward the total
            countryCount = visitedCountries.filter { country in
                guard let code = country.regionCode else { return true }
                return !RegionLookupService.isTerritory(code)
            }.count
            continentCount = visitedContinents.count

            let territoriesCount = visitedStates.count - stateCount
            debugLog("📍 RegionTrackingManager: Loaded \(stateCount) states + \(territoriesCount) DC/territories, \(countryCount) countries, \(continentCount) continents")
        } catch {
            debugLog("⚠️ RegionTrackingManager: Failed to load visited regions: \(error.localizedDescription)")
        }
    }

    /// Migrate existing records to populate missing regionCode fields
    private func migrateRegionCodes(stateEntries: [RecordHistoryEntry], countryEntries: [RecordHistoryEntry], continentEntries: [RecordHistoryEntry]) {
        var needsSave = false
        let lookupService = RegionLookupService.shared

        // Migrate state entries
        for entry in stateEntries where entry.regionCode == nil {
            if let locationName = entry.locationName,
               let stateCode = lookupService.stateCodeForName(locationName) {
                entry.regionCode = stateCode
                needsSave = true
                debugLog("✅ Migrated state '\(locationName)' with code '\(stateCode)'")
            } else {
                debugLog("⚠️ Could not find code for state: \(entry.locationName ?? "unknown")")
            }
        }

        // Migrate country entries
        for entry in countryEntries where entry.regionCode == nil {
            if let locationName = entry.locationName,
               let countryCode = lookupService.countryCodeForName(locationName) {
                entry.regionCode = countryCode
                needsSave = true
                debugLog("✅ Migrated country '\(locationName)' with code '\(countryCode)'")
            } else {
                debugLog("⚠️ Could not find code for country: \(entry.locationName ?? "unknown")")
            }
        }

        // Migrate continent entries (continent name is the "code")
        for entry in continentEntries where entry.regionCode == nil {
            if let locationName = entry.locationName {
                entry.regionCode = locationName  // For continents, name is the identifier
                needsSave = true
                debugLog("✅ Migrated continent '\(locationName)'")
            }
        }

        if needsSave {
            saveContext()
            debugLog("✅ Region code migration complete")
        }
    }

    /// Migrate: If US states exist but US country doesn't, add the US country
    private func migrateUSCountryIfNeeded() {
        // Check if US country already exists
        let usRequest: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()
        usRequest.predicate = NSPredicate(format: "regionCode == %@", "US")
        usRequest.fetchLimit = 1

        if let _ = try? context.fetch(usRequest).first {
            return  // US country already exists
        }

        // Check if any US states exist
        let statesRequest: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()
        statesRequest.predicate = NSPredicate(format: "regionCode BEGINSWITH %@ AND regionType == %@", "US-", RegionType.state.rawValue)

        guard let usStates = try? context.fetch(statesRequest), !usStates.isEmpty else {
            return  // No US states
        }

        // Collect all visit dates from US states
        var allDates: [Date] = []
        for state in usStates {
            allDates.append(contentsOf: state.visitDatesArray)
        }

        // Add US country with all the state visit dates
        let usCountry = VisitedRegion(context: context)
        usCountry.regionCode = "US"
        usCountry.regionName = "United States"
        usCountry.regionType = RegionType.country.rawValue
        usCountry.visitDates = Array(Set(allDates)).sorted() as NSArray

        saveContext()
        debugLog("📍 Migrated: Added US country with \(allDates.count) visit dates from \(usStates.count) states")
    }

    /// Deduplicate regions with the same regionCode, merging visit dates
    private func deduplicateRegions() {
        let request: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()

        guard let allRegions = try? context.fetch(request) else { return }

        // Group by regionCode
        var regionsByCode: [String: [VisitedRegion]] = [:]
        for region in allRegions {
            guard let code = region.regionCode else { continue }
            regionsByCode[code, default: []].append(region)
        }

        var needsSave = false

        // For each code with duplicates, merge into one and delete the rest
        for (code, regions) in regionsByCode where regions.count > 1 {
            // Keep the first one, merge others into it
            let keeper = regions[0]
            var allDates = (keeper.visitDates as? [Date]) ?? []

            for i in 1..<regions.count {
                let duplicate = regions[i]
                let dupDates = (duplicate.visitDates as? [Date]) ?? []
                allDates.append(contentsOf: dupDates)
                context.delete(duplicate)
            }

            // Dedupe and sort dates
            allDates = Array(Set(allDates)).sorted()
            keeper.visitDates = allDates as NSArray

            debugLog("📍 Deduplicated region '\(code)': merged \(regions.count) entries into one with \(allDates.count) visit dates")
            needsSave = true
        }

        if needsSave {
            saveContext()
        }
    }

    /// Clean up regions with invalid codes (e.g., "-99" from GeoJSON data issues)
    /// and migrate old FIPS-based state codes to postal codes
    private func cleanupInvalidRegionCodes(_ regions: [VisitedRegion]) {
        var needsSave = false

        for region in regions {
            // First, try to migrate FIPS state codes to postal codes
            if migrateStateCodeIfNeeded(region) {
                needsSave = true
                continue
            }

            // Then handle invalid codes like "-99"
            guard let code = region.regionCode, code == "-99" || code.hasPrefix("-") else {
                continue
            }

            // Try to fix the code based on the region name
            if let name = region.regionName, let correctCode = correctCodeForName(name) {
                // Check if we already have a region with the correct code
                let existingRequest: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()
                existingRequest.predicate = NSPredicate(format: "regionCode == %@", correctCode)

                if let existing = try? context.fetch(existingRequest).first {
                    // Merge visit dates into existing region
                    var existingDates = (existing.visitDates as? [Date]) ?? []
                    let newDates = (region.visitDates as? [Date]) ?? []
                    existingDates.append(contentsOf: newDates)
                    existingDates = Array(Set(existingDates)).sorted()  // Dedupe and sort
                    existing.visitDates = existingDates as NSArray

                    // Delete the invalid region
                    context.delete(region)
                    debugLog("📍 Merged region '\(name)' with invalid code '\(code)' into existing '\(correctCode)'")
                } else {
                    // Just update the code
                    region.regionCode = correctCode
                    debugLog("📍 Fixed region '\(name)' code from '\(code)' to '\(correctCode)'")
                }
                needsSave = true
            } else {
                // Can't fix, delete the invalid region
                debugLog("⚠️ Deleting region with unfixable invalid code: \(region.regionName ?? "unknown") (\(code))")
                context.delete(region)
                needsSave = true
            }
        }

        if needsSave {
            saveContext()
        }
    }

    /// Lookup correct ISO code for a country name (for fixing invalid data)
    private func correctCodeForName(_ name: String) -> String? {
        let lookup: [String: String] = [
            "France": "FR",
            "Norway": "NO",
            "Kosovo": "XK",
            "Somaliland": "SO",
        ]
        return lookup[name]
    }

    /// Convert old FIPS-based state codes to postal codes
    /// e.g., "US-06" -> "US-CA"
    private func migrateStateCodeIfNeeded(_ region: VisitedRegion) -> Bool {
        guard let code = region.regionCode,
              code.hasPrefix("US-"),
              region.regionType == RegionType.state.rawValue else {
            return false
        }

        let stateCode = String(code.dropFirst(3))

        // FIPS to postal mapping (50 states only, excludes DC)
        let fipsToPostal: [String: String] = [
            "01": "AL", "02": "AK", "04": "AZ", "05": "AR", "06": "CA",
            "08": "CO", "09": "CT", "10": "DE", "12": "FL",
            "13": "GA", "15": "HI", "16": "ID", "17": "IL", "18": "IN",
            "19": "IA", "20": "KS", "21": "KY", "22": "LA", "23": "ME",
            "24": "MD", "25": "MA", "26": "MI", "27": "MN", "28": "MS",
            "29": "MO", "30": "MT", "31": "NE", "32": "NV", "33": "NH",
            "34": "NJ", "35": "NM", "36": "NY", "37": "NC", "38": "ND",
            "39": "OH", "40": "OK", "41": "OR", "42": "PA", "44": "RI",
            "45": "SC", "46": "SD", "47": "TN", "48": "TX", "49": "UT",
            "50": "VT", "51": "VA", "53": "WA", "54": "WV", "55": "WI",
            "56": "WY"
        ]

        // Check if it's a FIPS code that needs migration
        if let postalCode = fipsToPostal[stateCode] {
            let newCode = "US-\(postalCode)"
            debugLog("📍 Migrating state code from '\(code)' to '\(newCode)'")
            region.regionCode = newCode
            return true
        }

        // Delete DC entries (not a state)
        if stateCode == "11" || stateCode == "DC" {
            debugLog("📍 Removing DC entry (not a state)")
            context.delete(region)
            return true
        }

        return false
    }

    // MARK: - Private Methods

    private func addVisitToRegion(code: String, name: String, type: RegionType, date: Date, coordinate: CLLocationCoordinate2D, altitude: Double = 0, photoAssetIdentifier: String? = nil, photoCloudIdentifier: String? = nil, suppressNotifications: Bool = false, suppressPhotoPrompts: Bool = false) {
        // Determine record type
        let recordTypeString: String
        switch type {
        case .state:
            recordTypeString = RecordType.state.rawValue
        case .country:
            recordTypeString = RecordType.country.rawValue
        }

        // Check if we already have a record for this region
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "recordType == %@ AND regionCode == %@", recordTypeString, code)
        request.fetchLimit = 1

        if let existingEntry = try? context.fetch(request).first {
            // Already have a record for this region
            var didUpdate = false

            // Update photo identifiers if not present
            if photoAssetIdentifier != nil && existingEntry.photoAssetIdentifier == nil {
                existingEntry.photoAssetIdentifier = photoAssetIdentifier
                existingEntry.photoCloudIdentifier = photoCloudIdentifier
                didUpdate = true
                debugLog("📸 Updated existing region record '\(name)' with photo identifiers")
            }

            // Update timestamp if this photo is older (earlier first visit)
            if let existingTimestamp = existingEntry.timestamp, date < existingTimestamp {
                existingEntry.timestamp = date
                existingEntry.value = date.timeIntervalSince1970
                didUpdate = true
                debugLog("📅 Updated existing region record '\(name)' with earlier date: \(date)")
            }

            if didUpdate {
                saveContext()
                loadVisitedRegions()  // Reload to update UI
            }
            return
        }

        // Check if this is the home region - skip if it is
        if let homeCoord = SettingsManager.shared.homeCoordinate {
            if let homeRegion = RegionLookupService.shared.region(for: homeCoord) {
                if homeRegion.code == code {
                    debugLog("📍 RegionTrackingManager: Skipping home region \(name)")
                    return
                }
            }
        }

        // Create new region record
        let detail = RecordDetail(
            value: date.timeIntervalSince1970,  // Store timestamp as value
            timestamp: date,
            coordinate: coordinate,
            altitude: altitude,
            locationName: name,
            recordType: recordTypeString,
            timeFrame: .allTime,  // Region records are always lifetime
            photoAssetIdentifier: photoAssetIdentifier,
            photoCloudIdentifier: photoCloudIdentifier,
            notes: nil,
            dateAdded: Date(),
            regionCode: code
        )

        let newEntry = RecordHistoryEntry(context: context)
        newEntry.id = detail.id
        newEntry.recordType = detail.recordType
        newEntry.timeFrame = detail.timeFrame.rawValue
        newEntry.value = detail.value
        newEntry.timestamp = detail.timestamp
        newEntry.latitude = detail.coordinate.latitude
        newEntry.longitude = detail.coordinate.longitude
        newEntry.altitude = detail.altitude
        newEntry.locationName = detail.locationName
        newEntry.regionCode = code  // Store region code
        newEntry.photoAssetIdentifier = detail.photoAssetIdentifier
        newEntry.photoCloudIdentifier = detail.photoCloudIdentifier
        newEntry.notes = detail.notes
        newEntry.dateAdded = detail.dateAdded

        saveContext()

        debugLog("📍 RegionTrackingManager: Created new region record for \(name) (\(recordTypeString))")

        // Send notification (unless suppressed)
        if !suppressNotifications && SettingsManager.shared.notifyOnNewRegion {
            sendNewRegionNotification(name: name, type: type)
        }

        // Prompt for photo (unless suppressed)
        if !suppressPhotoPrompts && SettingsManager.shared.photoPromptsEnabled {
            RecordManager.shared.promptForPhoto(recordType: recordTypeString, detail: detail)
        }

        // If this is a US state, also record US country (propagate suppression flags and photo identifiers)
        if type == .state && code.hasPrefix("US-") {
            addVisitToRegion(code: "US", name: "United States", type: .country, date: date, coordinate: coordinate, altitude: altitude, photoAssetIdentifier: photoAssetIdentifier, photoCloudIdentifier: photoCloudIdentifier, suppressNotifications: suppressNotifications, suppressPhotoPrompts: suppressPhotoPrompts)
        }

        // If this is a country, also record the continent (propagate suppression flags and photo identifiers)
        if type == .country {
            if let continent = getContinentForCountry(code: code) {
                addContinentVisit(continent: continent, date: date, coordinate: coordinate, altitude: altitude, photoAssetIdentifier: photoAssetIdentifier, photoCloudIdentifier: photoCloudIdentifier, suppressNotifications: suppressNotifications, suppressPhotoPrompts: suppressPhotoPrompts)
            }
        }

        // Reload to update UI
        loadVisitedRegions()
    }

    private func addContinentVisit(continent: String, date: Date, coordinate: CLLocationCoordinate2D, altitude: Double, photoAssetIdentifier: String? = nil, photoCloudIdentifier: String? = nil, suppressNotifications: Bool = false, suppressPhotoPrompts: Bool = false) {
        let recordTypeString = RecordType.continent.rawValue

        // Check if we already have a record for this continent
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "recordType == %@ AND regionCode == %@", recordTypeString, continent)
        request.fetchLimit = 1

        if let existingEntry = try? context.fetch(request).first {
            // Already have a record for this continent
            var didUpdate = false

            // Update photo identifiers if not present
            if photoAssetIdentifier != nil && existingEntry.photoAssetIdentifier == nil {
                existingEntry.photoAssetIdentifier = photoAssetIdentifier
                existingEntry.photoCloudIdentifier = photoCloudIdentifier
                didUpdate = true
                debugLog("📸 Updated existing continent record '\(continent)' with photo identifiers")
            }

            // Update timestamp if this photo is older (earlier first visit)
            if let existingTimestamp = existingEntry.timestamp, date < existingTimestamp {
                existingEntry.timestamp = date
                existingEntry.value = date.timeIntervalSince1970
                didUpdate = true
                debugLog("📅 Updated existing continent record '\(continent)' with earlier date: \(date)")
            }

            if didUpdate {
                saveContext()
                loadVisitedRegions()  // Reload to update UI
            }
            return
        }

        // Check if this is the home continent - skip if it is
        if let homeCoord = SettingsManager.shared.homeCoordinate {
            if let homeRegion = RegionLookupService.shared.region(for: homeCoord) {
                if let homeContinentString = getContinentForCountry(code: homeRegion.code),
                   homeContinentString == continent {
                    debugLog("📍 RegionTrackingManager: Skipping home continent \(continent)")
                    return
                }
            }
        }

        // Create new continent record
        let detail = RecordDetail(
            value: date.timeIntervalSince1970,
            timestamp: date,
            coordinate: coordinate,
            altitude: altitude,
            locationName: continent,
            recordType: recordTypeString,
            timeFrame: .allTime,
            photoAssetIdentifier: photoAssetIdentifier,
            photoCloudIdentifier: photoCloudIdentifier,
            notes: nil,
            dateAdded: Date(),
            regionCode: continent
        )

        let newEntry = RecordHistoryEntry(context: context)
        newEntry.id = detail.id
        newEntry.recordType = detail.recordType
        newEntry.timeFrame = detail.timeFrame.rawValue
        newEntry.value = detail.value
        newEntry.timestamp = detail.timestamp
        newEntry.latitude = detail.coordinate.latitude
        newEntry.longitude = detail.coordinate.longitude
        newEntry.altitude = detail.altitude
        newEntry.locationName = detail.locationName
        newEntry.regionCode = continent  // Store continent name as region code
        newEntry.photoAssetIdentifier = detail.photoAssetIdentifier
        newEntry.photoCloudIdentifier = detail.photoCloudIdentifier
        newEntry.notes = detail.notes
        newEntry.dateAdded = detail.dateAdded

        saveContext()

        debugLog("📍 RegionTrackingManager: Created new continent record for \(continent)")

        // Send notification (unless suppressed)
        if !suppressNotifications && SettingsManager.shared.notifyOnNewRegion {
            sendNewContinentNotification(name: continent)
        }

        // Prompt for photo (unless suppressed)
        if !suppressPhotoPrompts && SettingsManager.shared.photoPromptsEnabled {
            RecordManager.shared.promptForPhoto(recordType: recordTypeString, detail: detail)
        }

        // Reload to update UI
        loadVisitedRegions()
    }

    private func saveContext() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            debugLog("⚠️ RegionTrackingManager: Failed to save context: \(error.localizedDescription)")
        }
    }

    /// Deduplicate records by regionCode (or locationName as fallback), keeping the one with the earliest timestamp
    /// This handles duplicates that can be created by iCloud sync or code format changes (e.g., "CA" vs "US-CA")
    private func deduplicateByRegionCode(_ records: [RecordDetail]) -> [RecordDetail] {
        var seen: [String: RecordDetail] = [:]

        for record in records {
            // Use regionCode if available, otherwise fall back to locationName
            var key = record.regionCode ?? record.locationName ?? record.id.uuidString

            // Normalize US state codes: "CA" and "US-CA" should be treated as the same
            // If it's a 2-letter code that matches a US state, normalize to US-XX format
            if key.count == 2 && !key.hasPrefix("US-") {
                let usStateCodes = Set(["AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
                                        "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
                                        "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
                                        "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
                                        "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
                                        "DC", "AS", "GU", "MP", "PR", "VI"])
                if usStateCodes.contains(key) {
                    key = "US-\(key)"
                }
            }

            if let existing = seen[key] {
                // Keep the one with the earlier timestamp (first visit)
                if record.timestamp < existing.timestamp {
                    seen[key] = record
                }
            } else {
                seen[key] = record
            }
        }

        // Return sorted by timestamp (earliest first)
        return seen.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Send a notification when entering a new region
    private func sendNewRegionNotification(name: String, type: RegionType) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            guard settings.authorizationStatus == .authorized else {
                debugLog("⚠️ Cannot send new region notification - authorization status: \(settings.authorizationStatus.rawValue)")
                return
            }

            let content = UNMutableNotificationContent()

            switch type {
            case .state:
                content.title = "New State Visited!"
                content.body = "Welcome to \(name)"
            case .country:
                content.title = "New Country Visited!"
                content.body = "Welcome to \(name)"
            }

            content.sound = .default
            content.categoryIdentifier = "NEW_REGION"

            let request = UNNotificationRequest(
                identifier: "new-region-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await center.add(request)
                debugLog("📍 Sent new region notification for \(name)")
            } catch {
                debugLog("❌ Failed to send new region notification: \(error.localizedDescription)")
            }
        }
    }

    /// Send a notification when entering a new continent
    private func sendNewContinentNotification(name: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            guard settings.authorizationStatus == .authorized else {
                debugLog("⚠️ Cannot send new continent notification - authorization status: \(settings.authorizationStatus.rawValue)")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "New Continent Visited!"
            content.body = "Welcome to \(name)"
            content.sound = .default
            content.categoryIdentifier = "NEW_REGION"

            let request = UNNotificationRequest(
                identifier: "new-continent-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await center.add(request)
                debugLog("📍 Sent new continent notification for \(name)")
            } catch {
                debugLog("❌ Failed to send new continent notification: \(error.localizedDescription)")
            }
        }
    }

    private func getContinentForCountry(code: String) -> String? {
        // Use RegionLookupService to get continent
        for country in RegionLookupService.shared.allCountries {
            if country.code == code {
                return country.continent?.rawValue
            }
        }
        return nil
    }
}

// MARK: - VisitedRegion Extensions

extension VisitedRegion {
    /// Access visitDates as Swift [Date] array
    var visitDatesArray: [Date] {
        (visitDates as? [Date]) ?? []
    }

    /// First visit date (earliest in visitDates array)
    var firstVisitDate: Date? {
        visitDatesArray.min()
    }

    /// Last visit date (most recent in visitDates array)
    var lastVisitDate: Date? {
        visitDatesArray.max()
    }

    /// Number of distinct visit days
    var visitCount: Int {
        visitDatesArray.count
    }

    /// Visit dates filtered by year
    func visitDatesInYear(_ year: Int) -> [Date] {
        let calendar = Calendar.current
        return visitDatesArray.filter { calendar.component(.year, from: $0) == year }
    }

    /// Visit dates filtered by month and year
    func visitDatesInMonth(_ month: Int, year: Int) -> [Date] {
        let calendar = Calendar.current
        return visitDatesArray.filter {
            calendar.component(.year, from: $0) == year &&
            calendar.component(.month, from: $0) == month
        }
    }
}
