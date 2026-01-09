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
            altitude: alt,
            source: source
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
                    suppressPhotoPrompts: true,   // Already came from photos
                    source: .photo
                )
            }
        }

        saveContext()
        loadVisitedRegions()
    }

    /// Add region records for the home location (state, country, continent)
    /// Called when user sets their home location in settings or setup wizard
    /// Creates records silently without notifications
    func addHomeRegionRecords() {
        guard let homeCoord = SettingsManager.shared.homeCoordinate else {
            debugLog("📍 RegionTrackingManager: No home coordinate set, skipping home region records")
            return
        }

        guard let homeRegion = RegionLookupService.shared.region(for: homeCoord) else {
            debugLog("📍 RegionTrackingManager: Could not determine region for home coordinate")
            return
        }

        let now = Date()
        var addedAny = false

        // 1. Add state record if this is a US state
        if homeRegion.type == .state {
            if !regionExists(code: homeRegion.code) {
                createRegionRecord(
                    code: homeRegion.code,
                    name: homeRegion.name,
                    recordType: .state,
                    coordinate: homeCoord,
                    date: now,
                    source: .home
                )
                addedAny = true
            }

            // Also add the country (US) if not already present
            if !regionExists(code: "US") {
                createRegionRecord(
                    code: "US",
                    name: "United States",
                    recordType: .country,
                    coordinate: homeCoord,
                    date: now,
                    source: .home
                )
                addedAny = true
            }
        } else if homeRegion.type == .country {
            // 2. Add country record
            if !regionExists(code: homeRegion.code) {
                createRegionRecord(
                    code: homeRegion.code,
                    name: homeRegion.name,
                    recordType: .country,
                    coordinate: homeCoord,
                    date: now,
                    source: .home
                )
                addedAny = true
            }
        }

        // 3. Add continent record
        if let continent = homeRegion.continent {
            if !regionExists(code: continent.rawValue) {
                createRegionRecord(
                    code: continent.rawValue,
                    name: continent.rawValue,
                    recordType: .continent,
                    coordinate: homeCoord,
                    date: now,
                    source: .home
                )
                addedAny = true
            }
        }

        if addedAny {
            saveContext()
            loadVisitedRegions()  // Reload to update published properties
        }
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
        // First, ensure the home region exists (fixes previously skipped home regions)
        migrateHomeRegionIfNeeded()

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
            stateCount = visitedStates.filter { state in
                guard let code = state.regionCode else { return false }
                return !nonStateCodesForCount.contains(code)
            }.count

            // Count only sovereign countries (exclude territories) for the "X of 195" display
            // Territories still appear as cards but don't count toward the total
            countryCount = visitedCountries.filter { country in
                guard let code = country.regionCode else { return true }
                return !isTerritory(code)
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

        // Migrate country entries (includes territories like Azores, Madeira, etc.)
        for entry in countryEntries where entry.regionCode == nil {
            if let locationName = entry.locationName,
               let countryCode = lookupService.countryOrTerritoryCodeForName(locationName) {
                entry.regionCode = countryCode
                needsSave = true
                debugLog("✅ Migrated country/territory '\(locationName)' with code '\(countryCode)'")
            } else {
                debugLog("⚠️ Could not find code for country/territory: \(entry.locationName ?? "unknown")")
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

        // Migrate records that have parent country codes but should be territory codes
        // (e.g., records in Azores with code "PT" should be "PT-20")
        for entry in countryEntries where entry.regionCode == "PT" {
            let lat = entry.latitude
            let lon = entry.longitude
            // Check if in Azores bounding box
            if lat >= 36.9 && lat <= 39.75 && lon >= -31.3 && lon <= -25.0 {
                entry.regionCode = "PT-20"
                needsSave = true
                debugLog("✅ Migrated Portugal record to Azores (PT-20)")
            }
            // Check if in Madeira bounding box
            else if lat >= 32.6 && lat <= 33.15 && lon >= -17.3 && lon <= -16.25 {
                entry.regionCode = "PT-30"
                needsSave = true
                debugLog("✅ Migrated Portugal record to Madeira (PT-30)")
            }
        }

        // Similar migration for Spain -> Canary Islands
        for entry in countryEntries where entry.regionCode == "ES" {
            let lat = entry.latitude
            let lon = entry.longitude
            // Check if in Canary Islands bounding box
            if lat >= 27.6 && lat <= 29.5 && lon >= -18.2 && lon <= -13.3 {
                entry.regionCode = "ES-CN"
                needsSave = true
                debugLog("✅ Migrated Spain record to Canary Islands (ES-CN)")
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

    /// Migrate: Add the home region if it doesn't exist
    /// This fixes the issue where home regions were previously skipped
    /// Called before loading regions, so we create the entry directly without triggering reload
    /// Now creates state (if applicable), country, AND continent records
    private func migrateHomeRegionIfNeeded() {
        guard let homeCoord = SettingsManager.shared.homeCoordinate else {
            return  // No home set
        }

        guard let homeRegion = RegionLookupService.shared.region(for: homeCoord) else {
            return  // Couldn't determine home region
        }

        let now = Date()
        var addedAny = false

        // 1. Add state record if this is a US state
        if homeRegion.type == .state {
            if !regionExists(code: homeRegion.code) {
                createRegionRecord(
                    code: homeRegion.code,
                    name: homeRegion.name,
                    recordType: .state,
                    coordinate: homeCoord,
                    date: now,
                    source: .home,
                    logPrefix: "Adding missing home region"
                )
                addedAny = true
            }

            // Also add the country (US) if not already present
            if !regionExists(code: "US") {
                createRegionRecord(
                    code: "US",
                    name: "United States",
                    recordType: .country,
                    coordinate: homeCoord,
                    date: now,
                    source: .home,
                    logPrefix: "Adding missing home region"
                )
                addedAny = true
            }
        } else if homeRegion.type == .country {
            // 2. Add country record
            if !regionExists(code: homeRegion.code) {
                createRegionRecord(
                    code: homeRegion.code,
                    name: homeRegion.name,
                    recordType: .country,
                    coordinate: homeCoord,
                    date: now,
                    source: .home,
                    logPrefix: "Adding missing home region"
                )
                addedAny = true
            }
        }

        // 3. Add continent record
        if let continent = homeRegion.continent {
            if !regionExists(code: continent.rawValue) {
                createRegionRecord(
                    code: continent.rawValue,
                    name: continent.rawValue,
                    recordType: .continent,
                    coordinate: homeCoord,
                    date: now,
                    source: .home,
                    logPrefix: "Adding missing home region"
                )
                addedAny = true
            }
        }

        if addedAny {
            saveContext()
        }
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

        // Check if it's a FIPS code that needs migration (uses centralized mapping from Constants)
        if let postalCode = fipsToPostalCode[stateCode] {
            let newCode = "US-\(postalCode)"
            debugLog("📍 Migrating state code from '\(code)' to '\(newCode)'")
            region.regionCode = newCode
            return true
        }

        return false
    }

    // MARK: - Private Methods

    // MARK: Region Record Helpers
    // TODO: Add unit tests for regionExists() and createRegionRecord() when test coverage is expanded

    /// Check if a region record already exists by region code
    /// - Parameter code: The region code to check (e.g., "US-CA", "FR")
    /// - Returns: true if a record with this regionCode exists, false otherwise
    /// - Note: Returns false on fetch errors (logged via debugLog) for safe failure handling
    private func regionExists(code: String) -> Bool {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "regionCode == %@", code)
        request.fetchLimit = 1

        do {
            return try context.fetch(request).first != nil
        } catch {
            debugLog("❌ Error checking if region exists: \(error.localizedDescription)")
            return false  // Safe default: assume doesn't exist
        }
    }

    /// Create a new region record entry
    /// - Parameters:
    ///   - code: Region code (e.g., "US-CA", "FR", "Europe")
    ///   - name: Display name
    ///   - recordType: Type of region (state, country, continent)
    ///   - coordinate: GPS coordinate
    ///   - date: Timestamp for the record
    ///   - source: How the record was created (home, location, photo, etc.)
    ///   - logPrefix: Optional prefix for debug log (e.g., "Adding missing home region")
    private func createRegionRecord(
        code: String,
        name: String,
        recordType: RecordType,
        coordinate: CLLocationCoordinate2D,
        date: Date,
        source: RecordSource,
        logPrefix: String? = nil
    ) {
        let newEntry = RecordHistoryEntry(context: context)
        newEntry.id = UUID()
        newEntry.recordType = recordType.rawValue
        newEntry.timeFrame = TimeFrame.allTime.rawValue
        newEntry.value = date.timeIntervalSince1970
        newEntry.timestamp = date
        newEntry.latitude = coordinate.latitude
        newEntry.longitude = coordinate.longitude
        newEntry.altitude = 0
        newEntry.locationName = name
        newEntry.regionCode = code
        newEntry.dateAdded = date
        newEntry.source = source.rawValue

        // Single log message with optional prefix
        if let prefix = logPrefix {
            debugLog("📍 \(prefix): \(name) (\(code))")
        } else {
            debugLog("📍 RegionTrackingManager: Added region record: \(name) (\(code))")
        }
    }

    // MARK: Region Visit Recording

    private func addVisitToRegion(code: String, name: String, type: RegionType, date: Date, coordinate: CLLocationCoordinate2D, altitude: Double = 0, photoAssetIdentifier: String? = nil, photoCloudIdentifier: String? = nil, suppressNotifications: Bool = false, suppressPhotoPrompts: Bool = false, source: RecordSource = .location) {
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

        // Note: We no longer skip the home region - users should see their home state highlighted
        // on the map like any other visited region

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
            regionCode: code,
            source: source
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
        newEntry.source = source.rawValue

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

        // If this is a US state, also record US country (propagate suppression flags, photo identifiers, and source)
        if type == .state && code.hasPrefix("US-") {
            addVisitToRegion(code: "US", name: "United States", type: .country, date: date, coordinate: coordinate, altitude: altitude, photoAssetIdentifier: photoAssetIdentifier, photoCloudIdentifier: photoCloudIdentifier, suppressNotifications: suppressNotifications, suppressPhotoPrompts: suppressPhotoPrompts, source: source)
        }

        // If this is a country, also record the continent (propagate suppression flags, photo identifiers, and source)
        if type == .country {
            if let continent = getContinentForCountry(code: code) {
                addContinentVisit(continent: continent, date: date, coordinate: coordinate, altitude: altitude, photoAssetIdentifier: photoAssetIdentifier, photoCloudIdentifier: photoCloudIdentifier, suppressNotifications: suppressNotifications, suppressPhotoPrompts: suppressPhotoPrompts, source: source)
            }
        }

        // Reload to update UI
        loadVisitedRegions()
    }

    private func addContinentVisit(continent: String, date: Date, coordinate: CLLocationCoordinate2D, altitude: Double, photoAssetIdentifier: String? = nil, photoCloudIdentifier: String? = nil, suppressNotifications: Bool = false, suppressPhotoPrompts: Bool = false, source: RecordSource = .location) {
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

        // Note: We no longer skip the home continent - users should see their home continent highlighted
        // on the map like any other visited continent

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
            regionCode: continent,
            source: source
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
        newEntry.source = source.rawValue

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
            // Check if this is a state record to apply normalization
            let isState = record.recordType == RecordType.state.rawValue
            key = normalizeRegionCode(key, isState: isState)

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
