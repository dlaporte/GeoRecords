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

    var photoCount: Int { photoAssets.count }
}

// MARK: - Region Tracking Manager

/// Singleton manager for tracking visited regions
/// Coordinates visit recording from photos, location updates, and manual entries
@MainActor
class RegionTrackingManager: ObservableObject {
    static let shared = RegionTrackingManager()

    // MARK: - Published Properties

    @Published var visitedStates: [VisitedRegion] = []
    @Published var visitedCountries: [VisitedRegion] = []
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
            date: date
        )

        debugLog("📍 RegionTrackingManager: Recorded visit to \(regionInfo.name) via \(source.rawValue)")
    }

    /// Record visits for confirmed regions (after user confirmation in wizard)
    /// - Parameter regions: The confirmed DiscoveredRegion objects
    func recordConfirmedRegions(_ regions: [DiscoveredRegion]) {
        for region in regions where region.confirmed {
            // Get earliest photo date as the visit date
            let visitDates = region.photoAssets.compactMap { $0.creationDate }
            for date in visitDates {
                addVisitToRegion(
                    code: region.regionCode,
                    name: region.regionName,
                    type: region.regionType,
                    date: date
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

    /// Get visited continents (derived from visited countries)
    func getVisitedContinents() -> Set<Continent> {
        var continents = Set<Continent>()

        for country in visitedCountries {
            if let continentString = getContinentForCountry(code: country.regionCode ?? ""),
               let continent = Continent(rawValue: continentString) {
                continents.insert(continent)
            }
        }

        return continents
    }

    /// Reload visited regions from Core Data
    func loadVisitedRegions() {
        let request: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()

        do {
            let results = try context.fetch(request)

            // Clean up any regions with invalid codes (e.g., "-99" from bad GeoJSON data)
            cleanupInvalidRegionCodes(results)

            // Deduplicate regions with same code
            deduplicateRegions()

            // Migrate: Add US country if US states exist but US country doesn't
            migrateUSCountryIfNeeded()

            // Re-fetch after cleanup
            let cleanedResults = try context.fetch(request)

            visitedStates = cleanedResults.filter { $0.regionType == RegionType.state.rawValue }
            visitedCountries = cleanedResults.filter { $0.regionType == RegionType.country.rawValue }

            stateCount = visitedStates.count
            countryCount = visitedCountries.count
            continentCount = getVisitedContinents().count

            debugLog("📍 RegionTrackingManager: Loaded \(stateCount) states, \(countryCount) countries, \(continentCount) continents")
        } catch {
            debugLog("⚠️ RegionTrackingManager: Failed to load visited regions: \(error.localizedDescription)")
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

    private func addVisitToRegion(code: String, name: String, type: RegionType, date: Date) {
        // Find existing region or create new one
        let request: NSFetchRequest<VisitedRegion> = VisitedRegion.fetchRequest()
        request.predicate = NSPredicate(format: "regionCode == %@", code)
        request.fetchLimit = 1

        let region: VisitedRegion
        let isNewRegion: Bool
        if let existing = try? context.fetch(request).first {
            region = existing
            isNewRegion = false
        } else {
            region = VisitedRegion(context: context)
            region.regionCode = code
            region.regionName = name
            region.regionType = type.rawValue
            region.visitDates = NSArray()
            isNewRegion = true
        }

        // Add date if not already present (dedupe by calendar day)
        var dates = (region.visitDates as? [Date]) ?? []
        let calendar = Calendar.current

        let alreadyHasDate = dates.contains { existingDate in
            calendar.isDate(existingDate, inSameDayAs: date)
        }

        if !alreadyHasDate {
            dates.append(date)
            dates.sort()
            region.visitDates = dates as NSArray
        }

        saveContext()

        // Send notification if this is a new region
        if isNewRegion && SettingsManager.shared.notifyOnNewRegion {
            sendNewRegionNotification(name: name, type: type)
        }

        // If this is a US state, also record a visit to the US country
        if type == .state && code.hasPrefix("US-") {
            addVisitToRegion(code: "US", name: "United States", type: .country, date: date)
        }
    }

    private func saveContext() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            debugLog("⚠️ RegionTrackingManager: Failed to save context: \(error.localizedDescription)")
        }
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
