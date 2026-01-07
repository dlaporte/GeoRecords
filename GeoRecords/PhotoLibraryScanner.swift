import Foundation
import Photos
import CoreLocation
import UIKit

// MARK: - Type Aliases

/// Raw candidate from photo scanning before conversion to DiscoveredRecord
typealias PhotoCandidate = (value: Double, asset: PHAsset, location: CLLocation)

// MARK: - Discovered Record

// Discovered record from photo library
struct DiscoveredRecord: Identifiable, Equatable {
    let id = UUID()
    let recordType: String
    let value: Double
    let coordinate: CLLocationCoordinate2D
    let altitude: Double
    let timestamp: Date
    let photoAsset: PHAsset
    var selected: Bool = true
    var beatsTimeFrames: [TimeFrame]  // Which timeframes this record beats
    var locationName: String?  // Reverse geocoded location name

    static func == (lhs: DiscoveredRecord, rhs: DiscoveredRecord) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Import Wizard Data Structures

/// Wizard step for photo import flow
enum ImportWizardStep: Int, CaseIterable {
    case allTime = 0
    case yearly = 1
    case monthly = 2
    case states = 3     // Region confirmation: US states (before countries)
    case countries = 4  // Region confirmation: countries

    var title: String {
        switch self {
        case .allTime: return "Lifetime Records"
        case .yearly: return "Yearly Records"
        case .monthly: return "Monthly Records"
        case .states: return "States Visited"
        case .countries: return "Countries Visited"
        }
    }

    var shortTitle: String {
        switch self {
        case .allTime: return "Lifetime"
        case .yearly: return "Past Years"
        case .monthly: return "This Year"
        case .states: return "States"
        case .countries: return "Countries"
        }
    }

    var previousStep: ImportWizardStep? {
        switch self {
        case .allTime: return nil
        case .yearly: return .allTime
        case .monthly: return .yearly
        case .states: return .monthly
        case .countries: return .states
        }
    }

    var nextStep: ImportWizardStep? {
        switch self {
        case .allTime: return .yearly
        case .yearly: return .monthly
        case .monthly: return .states
        case .states: return .countries
        case .countries: return nil
        }
    }

    /// Whether this step is a region confirmation step
    var isRegionStep: Bool {
        self == .countries || self == .states
    }
}

/// Bucket for organizing candidates by year
struct YearBucket: Identifiable {
    let id: Int  // The year (e.g., 2024)
    var records: [String: [DiscoveredRecord]]  // recordType -> candidates (sorted by extremeness)

    var availableRecordTypes: [String] {
        RecordType.allTypeStrings.filter { records[$0]?.isEmpty == false }
    }

    var isEmpty: Bool {
        availableRecordTypes.isEmpty
    }
}

/// Bucket for organizing candidates by month (current year only)
struct MonthBucket: Identifiable {
    let id: Int  // 1-12 (January-December)
    let year: Int
    var records: [String: [DiscoveredRecord]]  // recordType -> candidates (sorted by extremeness)

    var displayName: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM"
        var components = DateComponents()
        components.month = id
        if let date = Calendar.current.date(from: components) {
            return dateFormatter.string(from: date)
        }
        return "Month \(id)"
    }

    var availableRecordTypes: [String] {
        RecordType.allTypeStrings.filter { records[$0]?.isEmpty == false }
    }

    var isEmpty: Bool {
        availableRecordTypes.isEmpty
    }
}

/// Tracks user selections across all wizard steps
struct WizardSelection {
    // All-time: recordType -> selectedIndex (0-based into candidates array)
    var allTime: [String: Int] = [:]

    // Yearly: year -> recordType -> selectedIndex
    var yearly: [Int: [String: Int]] = [:]

    // Monthly: "year-month" -> recordType -> selectedIndex
    var monthly: [String: [String: Int]] = [:]

    // Track which records already exist (key format: "timeframe_recordType" or "year_recordType" or "year-month_recordType")
    var existingRecords: Set<String> = []

    // Track which selections the user has modified from the default
    var userModified: Set<String> = []

    // Track the initial/default selections to compare against
    var initialSelections: [String: Int] = [:]

    static func monthKey(year: Int, month: Int) -> String {
        return "\(year)-\(String(format: "%02d", month))"
    }

    static func selectionKey(timeFrame: String, recordType: String) -> String {
        return "\(timeFrame)_\(recordType)"
    }

    /// Check if a record exists for the given timeframe and record type
    func recordExists(timeFrame: String, recordType: String) -> Bool {
        return existingRecords.contains(Self.selectionKey(timeFrame: timeFrame, recordType: recordType))
    }

    /// Check if user modified the selection for the given timeframe and record type
    func isModified(timeFrame: String, recordType: String) -> Bool {
        return userModified.contains(Self.selectionKey(timeFrame: timeFrame, recordType: recordType))
    }

    /// Mark a selection as modified
    mutating func markModified(timeFrame: String, recordType: String) {
        let key = Self.selectionKey(timeFrame: timeFrame, recordType: recordType)
        userModified.insert(key)
        debugLog("📝 markModified: \(key)")
    }
}

/// Tracks records that should be deleted (user skipped existing records)
struct RecordToDelete {
    let recordType: String
    let timeFrame: TimeFrame
    let year: Int?
    let month: Int?
}

@MainActor
class PhotoLibraryScanner: ObservableObject {
    @Published var isScanning = false
    @Published var isProcessing = false  // Post-scan processing phase (sorting, bucketing)
    @Published var progress: Double = 0
    @Published var totalPhotos = 0
    @Published var scannedPhotos = 0
    @Published var photosWithLocation = 0
    @Published var discoveredRecords: [DiscoveredRecord] = []  // Currently displayed record(s)
    @Published var errorMessage: String?

    // Import status tracking
    @Published var isImporting = false
    @Published var importProgress: (current: Int, total: Int) = (0, 0)

    // Three-phase confirmation flow (legacy - kept for compatibility during transition)
    @Published var currentTimeFrame: TimeFrame? = nil  // Current phase: month, year, or allTime
    @Published var currentRecordTypeIndex = 0  // Index into recordTypes array
    @Published var isConfirming = false

    private let recordTypes = RecordType.allTypeStrings

    // Candidates organized by timeframe, then record type (sorted by extremeness)
    private var candidatesByTimeFrame: [TimeFrame: [String: [DiscoveredRecord]]] = [:]
    private var currentCandidateIndices: [String: Int] = [:]  // Key format: "timeFrame_recordType"
    var confirmedRecords: [DiscoveredRecord] = []  // All confirmed records for import

    /// Records to clear when user skips existing ones
    var recordsToDelete: [RecordToDelete] = []

    // MARK: - Import Wizard State

    /// Reorganized candidate storage for wizard
    @Published var allTimeCandidates: [String: [DiscoveredRecord]] = [:]  // recordType -> sorted candidates
    @Published var yearlyBuckets: [YearBucket] = []  // Sorted descending by year
    @Published var monthlyBuckets: [MonthBucket] = []  // Current year only, sorted by month

    /// Selection state for wizard
    @Published var wizardSelections = WizardSelection()

    /// Current wizard step
    @Published var currentWizardStep: ImportWizardStep = .allTime

    /// Whether wizard mode is active (vs legacy confirmation flow)
    @Published var isWizardMode = false

    // MARK: - Discovered Regions State

    /// Countries discovered during photo scan (pending user confirmation)
    @Published var discoveredCountries: [DiscoveredRegion] = []

    /// US States discovered during photo scan (pending user confirmation)
    @Published var discoveredStates: [DiscoveredRegion] = []

    /// Live counts during scanning (for progress display)
    @Published var discoveredCountryCount: Int = 0
    @Published var discoveredStateCount: Int = 0

    /// Temporary storage for regions during scan (keyed by region code)
    private var regionPhotoMap: [String: (info: RegionInfo, assets: [PHAsset])] = [:]

    /// Spatial cache for region lookups to avoid redundant point-in-polygon checks
    /// Key is a grid cell (lat/lon rounded to 0.01 degrees ~1km), value is the region code or nil
    private var regionLookupCache: [String: String?] = [:]

    /// Get cache key for a coordinate (grid cell of ~1km)
    private func regionCacheKey(lat: Double, lon: Double) -> String {
        let gridLat = (lat * 100).rounded() / 100
        let gridLon = (lon * 100).rounded() / 100
        return "\(gridLat),\(gridLon)"
    }

    func requestPhotoLibraryAccess(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            _ = Task { @MainActor in
                completion(status == .authorized)
            }
        }
    }

    func scanPhotoLibrary(homeCoordinate: CLLocationCoordinate2D?) async {
        guard !isScanning else { return }

        isScanning = true
        progress = 0
        scannedPhotos = 0
        photosWithLocation = 0
        discoveredRecords = []
        errorMessage = nil
        currentTimeFrame = nil
        currentRecordTypeIndex = 0
        isConfirming = false

        // Reset discovered regions
        discoveredCountries = []
        discoveredStates = []
        discoveredCountryCount = 0
        discoveredStateCount = 0
        regionPhotoMap = [:]
        regionLookupCache = [:]

        // Ensure region boundaries are loaded
        RegionLookupService.shared.loadBoundaries()
        candidatesByTimeFrame = [:]
        currentCandidateIndices = [:]
        confirmedRecords = []

        // Reset wizard state
        resetWizardState()

        // Fetch all photos (can't filter by location in predicate)
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let allPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        totalPhotos = allPhotos.count

        guard totalPhotos > 0 else {
            errorMessage = "No photos found in library"
            isScanning = false
            return
        }

        // Collect ALL candidates - we need per-year and per-month extremes, not just global
        var northCandidates: [PhotoCandidate] = []
        var southCandidates: [PhotoCandidate] = []
        var eastCandidates: [PhotoCandidate] = []
        var westCandidates: [PhotoCandidate] = []
        var upCandidates: [PhotoCandidate] = []
        var fromHomeCandidates: [PhotoCandidate] = []

        // Scan all photos asynchronously in batches
        let batchSize = photoScanBatchSize
        let count = allPhotos.count

        // Local cache for region lookups (avoids repeated expensive lookups)
        var localRegionCache: [String: String?] = [:]
        // Local cache for region info (to get name/type for new regions)
        var regionInfoCache: [String: RegionInfo] = [:]

        for batchStart in stride(from: 0, to: count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, count)
            var batchPhotosWithLocation = 0
            var batchRegionUpdates: [(code: String, asset: PHAsset, info: RegionInfo?)] = []
            var batchPhotoLocations: [(location: CLLocation, timestamp: Date)] = []

            // Process batch with autoreleasepool to prevent memory buildup
            autoreleasepool {
                for index in batchStart..<batchEnd {
                    let asset = allPhotos.object(at: index)

                    guard let location = asset.location,
                          asset.creationDate != nil else { continue }

                    let lat = location.coordinate.latitude
                    let lon = location.coordinate.longitude
                    let alt = location.altitude

                    // Skip invalid locations (Null Island or unrealistic altitude)
                    if case .valid = validateLocation(latitude: lat, longitude: lon, altitude: alt) {
                        // Location is valid, continue processing
                    } else {
                        continue
                    }

                    batchPhotosWithLocation += 1

                    // Collect photo location for daily statistics
                    if let photoDate = asset.creationDate {
                        batchPhotoLocations.append((location: location, timestamp: photoDate))
                    }

                    // Collect ALL candidates for each direction
                    northCandidates.append((lat, asset, location))
                    southCandidates.append((lat, asset, location))
                    eastCandidates.append((lon, asset, location))
                    westCandidates.append((lon, asset, location))
                    upCandidates.append((alt, asset, location))

                    // Distance from home
                    if let homeCoord = homeCoordinate {
                        let distance = distanceBetween(from: location.coordinate, to: homeCoord)
                        fromHomeCandidates.append((distance, asset, location))
                    }

                    // Collect region for this photo using spatial cache for performance
                    let cacheKey = self.regionCacheKey(lat: lat, lon: lon)

                    // Check cache first
                    if localRegionCache.keys.contains(cacheKey) {
                        // Double-unwrap: dictionary returns String??, we need String
                        if let regionCode = localRegionCache[cacheKey] ?? nil {
                            batchRegionUpdates.append((regionCode, asset, nil))
                        }
                        // else: cached as nil = no region for this grid cell
                    } else {
                        // Cache miss - do the expensive lookup
                        let regionInfo = RegionLookupService.shared.region(for: location.coordinate)
                        localRegionCache[cacheKey] = regionInfo?.code
                        if let regionInfo = regionInfo {
                            regionInfoCache[regionInfo.code] = regionInfo
                            batchRegionUpdates.append((regionInfo.code, asset, regionInfo))
                        }
                    }
                }
            }

            // Apply batch updates to MainActor (once per batch, not per photo)
            self.scannedPhotos = batchEnd
            self.progress = Double(batchEnd) / Double(self.totalPhotos)
            self.photosWithLocation += batchPhotosWithLocation

            // Apply region updates
            for (code, asset, info) in batchRegionUpdates {
                let isNewRegion = self.regionPhotoMap[code] == nil
                let currentCount = self.regionPhotoMap[code]?.assets.count ?? 0

                if currentCount < maxPhotosPerRegionDuringImport {
                    if self.regionPhotoMap[code] != nil {
                        self.regionPhotoMap[code]?.assets.append(asset)
                    } else if let info = info ?? regionInfoCache[code] {
                        self.regionPhotoMap[code] = (info: info, assets: [asset])
                    }
                }

                if isNewRegion, let info = info ?? regionInfoCache[code] {
                    switch info.type {
                    case .country:
                        self.discoveredCountryCount += 1
                    case .state:
                        self.discoveredStateCount += 1
                    }
                }
            }

            // Update daily records for photos from the current month only
            // Historical chart data comes from RecordHistoryEntry, not daily records
            let calendar = Calendar.current
            guard let currentMonthStart = calendar.dateInterval(of: .month, for: Date())?.start else {
                continue
            }

            for (photoLocation, photoTimestamp) in batchPhotoLocations {
                // Only create daily records for current month photos
                if photoTimestamp >= currentMonthStart {
                    await MainActor.run {
                        updateDailyRecordsForPhoto(location: photoLocation, date: photoTimestamp)
                    }
                }
            }

            // Brief yield to UI
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }

        debugLog("📊 Processed daily records for current month photos")

        // Create monthly RecordHistoryEntry records for all historical months
        // This enables the Stats tab to show location names when dragging over chart bars
        let monthlyRecordsCreated = await createMonthlyHistoricalRecords(
            northCandidates: northCandidates,
            southCandidates: southCandidates,
            eastCandidates: eastCandidates,
            westCandidates: westCandidates,
            upCandidates: upCandidates,
            fromHomeCandidates: fromHomeCandidates
        )
        debugLog("📊 Created \(monthlyRecordsCreated) monthly historical records for statistics")

        // Start background geocoding for the newly created monthly records
        if monthlyRecordsCreated > 0 {
            Task {
                await BackgroundGeocoder.shared.geocodeMissingLocations()
            }
        }

        // Scanning complete, now processing results
        isScanning = false
        isProcessing = true

        // Yield to UI so "Processing Results..." screen appears before heavy work
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Get current month and year boundaries
        let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

        let processingStart = Date()
        debugLog("📊 Processing: Starting with \(northCandidates.count) candidates per type")

        // Sort candidates by extremeness and keep top N PER YEAR and PER MONTH (current year)
        // This ensures each year AND each month has candidates for all record types
        // Same limit for all time periods - consistent infinite carousel behavior
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())

        func limitByTimePeriod(_ candidates: inout [PhotoCandidate], ascending: Bool) {
            // Sort by extremeness
            if ascending {
                candidates.sort { $0.value < $1.value }
            } else {
                candidates.sort { $0.value > $1.value }
            }

            // Group by year (and by month for current year)
            var byYear: [Int: [PhotoCandidate]] = [:]
            var byMonth: [Int: [PhotoCandidate]] = [:]  // Only for current year

            for candidate in candidates {
                guard let date = candidate.asset.creationDate else { continue }
                let year = calendar.component(.year, from: date)
                byYear[year, default: []].append(candidate)

                // Also track by month for current year
                if year == currentYear {
                    let month = calendar.component(.month, from: date)
                    byMonth[month, default: []].append(candidate)
                }
            }

            // Rebuild with limited candidates
            var limited: [PhotoCandidate] = []
            var addedIdentifiers = Set<String>()  // Avoid duplicates

            // Add top N per year (for past years)
            for (year, yearCandidates) in byYear where year != currentYear {
                for candidate in yearCandidates.prefix(maxCandidatesPerTimeFrameDuringImport) {
                    if !addedIdentifiers.contains(candidate.asset.localIdentifier) {
                        limited.append(candidate)
                        addedIdentifiers.insert(candidate.asset.localIdentifier)
                    }
                }
            }

            // Add top N per month for current year (ensures monthly buckets have data)
            for (_, monthCandidates) in byMonth {
                for candidate in monthCandidates.prefix(maxCandidatesPerTimeFrameDuringImport) {
                    if !addedIdentifiers.contains(candidate.asset.localIdentifier) {
                        limited.append(candidate)
                        addedIdentifiers.insert(candidate.asset.localIdentifier)
                    }
                }
            }

            // Also add top N for current year overall (for yearly bucket)
            if let currentYearCandidates = byYear[currentYear] {
                for candidate in currentYearCandidates.prefix(maxCandidatesPerTimeFrameDuringImport) {
                    if !addedIdentifiers.contains(candidate.asset.localIdentifier) {
                        limited.append(candidate)
                        addedIdentifiers.insert(candidate.asset.localIdentifier)
                    }
                }
            }

            // Re-sort by extremeness
            if ascending {
                limited.sort { $0.value < $1.value }
            } else {
                limited.sort { $0.value > $1.value }
            }
            candidates = limited
        }

        limitByTimePeriod(&northCandidates, ascending: false)  // Highest latitude first
        limitByTimePeriod(&southCandidates, ascending: true)   // Lowest latitude first
        limitByTimePeriod(&eastCandidates, ascending: false)   // Highest longitude first
        limitByTimePeriod(&westCandidates, ascending: true)    // Lowest longitude first
        limitByTimePeriod(&upCandidates, ascending: false)     // Highest altitude first
        limitByTimePeriod(&fromHomeCandidates, ascending: false)  // Furthest distance first

        debugLog("📊 Processing: Sort+limit took \(Date().timeIntervalSince(processingStart))s")

        // Convert and filter candidates by timeframe
        func buildCandidatesForTimeframe(
            _ candidates: [PhotoCandidate],
            recordType: String,
            timeFrame: TimeFrame,
            valueTransform: ((Double) -> Double)? = nil
        ) -> [DiscoveredRecord] {
            return candidates.compactMap { candidate in
                guard let timestamp = candidate.asset.creationDate else { return nil }

                // Filter by timeframe
                let qualifies: Bool
                switch timeFrame {
                case .daily:
                    qualifies = false  // Daily is not used for photo scanning
                case .month:
                    qualifies = timestamp >= startOfMonth
                case .year:
                    qualifies = timestamp >= startOfYear
                case .allTime:
                    qualifies = true
                }

                guard qualifies else { return nil }

                let finalValue = valueTransform?(candidate.value) ?? candidate.value
                return DiscoveredRecord(
                    recordType: recordType,
                    value: finalValue,
                    coordinate: candidate.location.coordinate,
                    altitude: candidate.location.altitude,
                    timestamp: timestamp,
                    photoAsset: candidate.asset,
                    selected: true,
                    beatsTimeFrames: [timeFrame],
                    locationName: nil
                )
            }
        }

        // Organize candidates by timeframe and record type
        let candidateSets: [(name: String, candidates: [PhotoCandidate], transform: ((Double) -> Double)?)] = [
            (RecordType.north.rawValue, northCandidates, nil),
            (RecordType.south.rawValue, southCandidates, nil),
            (RecordType.east.rawValue, eastCandidates, nil),
            (RecordType.west.rawValue, westCandidates, nil),
            (RecordType.up.rawValue, upCandidates, nil),
            (RecordType.fromHome.rawValue, fromHomeCandidates, nil)  // Store in meters (consistent with altitude)
        ]

        candidatesByTimeFrame = [
            .month: [:],
            .year: [:],
            .allTime: [:]
        ]

        for (recordType, candidates, transform) in candidateSets {
            for timeFrame in TimeFrame.allCases {
                let filteredCandidates = buildCandidatesForTimeframe(
                    candidates,
                    recordType: recordType,
                    timeFrame: timeFrame,
                    valueTransform: transform
                )
                candidatesByTimeFrame[timeFrame]?[recordType] = filteredCandidates

                // Initialize candidate index for this combination
                let key = "\(timeFrame.rawValue)_\(recordType)"
                currentCandidateIndices[key] = 0
            }
        }

        debugLog("📊 Processing: buildCandidatesForTimeframe took \(Date().timeIntervalSince(processingStart))s")

        // Convert collected regions to DiscoveredRegion arrays
        buildDiscoveredRegions()

        debugLog("📊 Processing: buildDiscoveredRegions took \(Date().timeIntervalSince(processingStart))s")

        // Check if we have any candidates across all timeframes
        var totalCandidates = 0
        for timeFrame in TimeFrame.allCases {
            for recordType in recordTypes {
                if let candidates = candidatesByTimeFrame[timeFrame]?[recordType], !candidates.isEmpty {
                    totalCandidates += 1
                }
            }
        }

        if totalCandidates == 0 {
            isProcessing = false
            if photosWithLocation == 0 {
                errorMessage = "No photos with location data found in your library"
            } else {
                errorMessage = "No records found that would beat your current records"
            }
        } else {
            // Organize into wizard buckets and start wizard mode
            organizeIntoTimeBuckets()
            debugLog("📊 Processing: organizeIntoTimeBuckets took \(Date().timeIntervalSince(processingStart))s total")
            isProcessing = false
            currentWizardStep = .allTime
            isWizardMode = true
            isConfirming = true  // Keep for compatibility with ImportPreviewView
        }
    }

    // Update discoveredRecords with the current record being shown
    private func updateCurrentRecord() {
        guard let timeFrame = currentTimeFrame else {
            isConfirming = false
            return
        }

        // Find next record type with candidates for this timeframe
        while currentRecordTypeIndex < recordTypes.count {
            let recordType = recordTypes[currentRecordTypeIndex]
            let key = "\(timeFrame.rawValue)_\(recordType)"
            let candidateIndex = currentCandidateIndices[key] ?? 0

            if let candidates = candidatesByTimeFrame[timeFrame]?[recordType],
               candidateIndex < candidates.count,
               let candidate = candidates[safe: candidateIndex] {
                // Found a candidate to show
                discoveredRecords = [candidate]
                return
            }

            // No more candidates for this record type, move to next
            currentRecordTypeIndex += 1
        }

        // No more record types in this timeframe, move to next timeframe
        advanceToNextTimeFrame()
    }

    private func advanceToNextTimeFrame() {
        guard let currentTF = currentTimeFrame else {
            isConfirming = false
            return
        }

        switch currentTF {
        case .daily:
            currentTimeFrame = .month  // Skip daily, move to month
        case .month:
            currentTimeFrame = .year
        case .year:
            currentTimeFrame = .allTime
        case .allTime:
            // Done with all timeframes
            isConfirming = false
            return
        }

        currentRecordTypeIndex = 0
        updateCurrentRecord()
    }

    func confirmCurrentRecord() {
        guard !discoveredRecords.isEmpty else { return }

        // Add to confirmed records for import
        confirmedRecords.append(discoveredRecords[0])

        // Move to next record
        advanceToNextRecord()
    }

    /// Confirm a specific candidate by index (used by swipeable carousel)
    func confirmCandidate(at index: Int) {
        let candidates = currentCandidates
        guard index >= 0, index < candidates.count else { return }

        // Add the selected candidate to confirmed records
        confirmedRecords.append(candidates[index])

        // Move to next record type
        advanceToNextRecord()
    }

    /// Skip this record type entirely (no photo selected)
    func skipRecordType() {
        advanceToNextRecord()
    }

    func rejectCurrentRecord() {
        guard let timeFrame = currentTimeFrame,
              currentRecordTypeIndex < recordTypes.count else {
            return
        }

        let recordType = recordTypes[currentRecordTypeIndex]
        let key = "\(timeFrame.rawValue)_\(recordType)"

        // Try next candidate for this type/timeframe
        if var candidateIndex = currentCandidateIndices[key] {
            candidateIndex += 1
            currentCandidateIndices[key] = candidateIndex

            if let candidates = candidatesByTimeFrame[timeFrame]?[recordType],
               candidateIndex < candidates.count,
               let candidate = candidates[safe: candidateIndex] {
                // Show next candidate
                discoveredRecords = [candidate]
                return
            }
        }

        // No more candidates for this type, mark as skipped and move to next
        advanceToNextRecord()
    }

    private func advanceToNextRecord() {
        currentRecordTypeIndex += 1
        updateCurrentRecord()
    }

    var currentRecord: DiscoveredRecord? {
        guard isConfirming, !discoveredRecords.isEmpty else {
            return nil
        }
        return discoveredRecords[0]
    }

    /// Get all candidates for the current record type and timeframe (for swipeable carousel)
    var currentCandidates: [DiscoveredRecord] {
        guard let timeFrame = currentTimeFrame,
              currentRecordTypeIndex < recordTypes.count else {
            return []
        }
        let recordType = recordTypes[currentRecordTypeIndex]
        return candidatesByTimeFrame[timeFrame]?[recordType] ?? []
    }

    var currentTimeFrameName: String {
        guard let timeFrame = currentTimeFrame else { return "" }
        return timeFrame.rawValue
    }

    var currentProgress: (current: Int, total: Int) {
        guard let timeFrame = currentTimeFrame else { return (0, 0) }

        // Calculate overall progress across all timeframes
        let allTimeframes = TimeFrame.allCases
        guard let currentTimeFrameIndex = allTimeframes.firstIndex(of: timeFrame) else {
            return (0, recordTypes.count * allTimeframes.count)
        }

        let completedTimeframes = currentTimeFrameIndex * recordTypes.count
        let currentInTimeframe = currentRecordTypeIndex
        let total = recordTypes.count * allTimeframes.count

        return (completedTimeframes + currentInTimeframe + 1, total)
    }

    /// Update the location name for a specific record
    func updateLocationName(for recordId: UUID, locationName: String) {
        if let index = discoveredRecords.firstIndex(where: { $0.id == recordId }) {
            discoveredRecords[index].locationName = locationName
        }
    }

    func importSelectedRecords(completion: @escaping (Int) -> Void) async {
        let selectedRecords = confirmedRecords
        let deletions = recordsToDelete

        // Reset import state
        await MainActor.run {
            isImporting = true
            importProgress = (0, selectedRecords.count)
        }

        // Block ALL alerts during import - this is foolproof
        await MainActor.run {
            RecordManager.shared.blockAlertsDuringImport(block: true)
        }

        // Process deletions first (records the user skipped that previously existed)
        if !deletions.isEmpty {
            await MainActor.run {
                for deletion in deletions {
                    debugLog("🗑️ Clearing skipped record: \(deletion.recordType) (\(deletion.timeFrame.rawValue))")
                    RecordManager.shared.clearRecord(
                        type: deletion.recordType,
                        timeFrame: deletion.timeFrame,
                        year: deletion.year,
                        month: deletion.month
                    )
                }
                debugLog("✅ Processed \(deletions.count) record deletion(s)")
            }
        }

        var successCount = 0

        for (index, record) in selectedRecords.enumerated() {
            // Update progress
            await MainActor.run {
                importProgress = (index, selectedRecords.count)
            }

            // Note: Daily statistics are now recorded for ALL geotagged photos during scan,
            // so we don't need to record them again here during import.

            // Get photo asset identifier (reference to Apple Photos library)
            let photoAssetIdentifier = record.photoAsset.localIdentifier
            debugLog("📸 Photo asset identifier: \(photoAssetIdentifier)")
            debugLog("📅 Photo timestamp (EXIF): \(record.timestamp)")

            // Get cloud identifier for cross-device access
            let photoCloudIdentifier = PHPhotoLibrary.cloudIdentifier(for: record.photoAsset)
            if let cloudId = photoCloudIdentifier {
                debugLog("☁️ Photo cloud identifier: \(cloudId)")
            }

            // Use the timeframes that were determined during scanning
            let timeFrames = record.beatsTimeFrames
            debugLog("📅 Importing \(record.recordType) for timeframes: \(timeFrames.map { $0.rawValue }.joined(separator: ", "))")

            // Create records for each applicable timeframe
            let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

            // Track if we've saved thumbnail for this photo (only need once per import)
            var thumbnailSaved = false

            for timeFrame in timeFrames {
                let detail = RecordDetail(
                    value: record.value,
                    timestamp: record.timestamp,
                    coordinate: record.coordinate,
                    altitude: record.altitude,
                    locationName: record.locationName,
                    recordType: record.recordType,
                    timeFrame: timeFrame,
                    photoAssetIdentifier: photoAssetIdentifier,
                    photoCloudIdentifier: photoCloudIdentifier
                )

                // Delete any existing record for this type/timeframe before adding new one
                // This ensures we don't accumulate duplicate records with different photos
                await MainActor.run {
                    RecordHistoryManager.shared.deleteExistingRecord(
                        type: record.recordType,
                        timeFrame: timeFrame,
                        timestamp: record.timestamp
                    )
                }

                // Add the new record to history
                _ = await MainActor.run {
                    RecordHistoryManager.shared.addRecord(recordType: record.recordType, detail: detail)
                }

                // Save thumbnail to cache (once per photo, for widget and fast loading)
                if !thumbnailSaved {
                    await ThumbnailCache.shared.saveThumbnail(from: record.photoAsset, for: detail.id)
                    thumbnailSaved = true
                }

                // Only update RecordManager if record belongs to CURRENT timeframe period
                // RecordManager tracks current records, not historical ones
                let shouldUpdateRecordManager: Bool
                switch timeFrame {
                case .daily:
                    shouldUpdateRecordManager = false  // Daily records are handled separately
                case .allTime:
                    shouldUpdateRecordManager = true
                case .year:
                    shouldUpdateRecordManager = record.timestamp >= startOfYear
                case .month:
                    shouldUpdateRecordManager = record.timestamp >= startOfMonth
                }

                if shouldUpdateRecordManager {
                    await MainActor.run {
                        // Use setRecord directly instead of updateRecordIfBetter
                        // The user explicitly selected this photo in the wizard, so we must respect
                        // their choice even if a "more extreme" record exists in memory.
                        // The old record was already deleted from Core Data above.
                        RecordManager.shared.setRecord(type: record.recordType, timeFrame: timeFrame, record: detail)
                        debugLog("📸 Updated in-memory record: \(record.recordType) (\(timeFrame.rawValue)) photo=\(detail.photoAssetIdentifier ?? "nil")")
                    }
                }
            }
            successCount += 1
        }

        await MainActor.run {
            importProgress = (selectedRecords.count, selectedRecords.count)
            isImporting = false

            // Log summary
            debugLog("✅ Import completed successfully. \(successCount) records imported.")

            // Unblock alerts after a delay
            _ = Task {
                try? await Task.sleep(nanoseconds: postImportNotificationSuppressionNanoseconds)
                RecordManager.shared.blockAlertsDuringImport(block: false)
            }

            // Also use the time-based suppression system as backup
            RecordManager.shared.suppressNotificationsAfterImport(durationSeconds: postImportNotificationSuppressionSeconds)

            // Persist user's skip choices for future wizard runs
            persistSkippedRecordChoices()

            completion(successCount)

            // Start background geocoding for any imported records missing location names
            Task {
                await BackgroundGeocoder.shared.geocodeMissingLocations()
            }

            // Run data cleanup and trigger CloudKit sync after import completes
            Task {
                // Clean up any duplicates or at-home records that may have been imported
                let cleaned = RecordHistoryManager.shared.performDataCleanup()
                if cleaned > 0 {
                    debugLog("🧹 Post-import cleanup: cleaned \(cleaned) record(s)")
                }

                let context = PersistenceController.shared.container.viewContext
                do {
                    // Ensure all changes are saved
                    if context.hasChanges {
                        try context.save()
                    }

                    // Give CloudKit a moment to pick up the changes
                    try await Task.sleep(nanoseconds: 500_000_000)

                    // Nudge CloudKit to notice the new records
                    context.refreshAllObjects()
                    debugLog("☁️ Triggered CloudKit export after photo import")
                } catch {
                    debugLog("⚠️ Error triggering CloudKit sync: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Import Wizard Methods

    /// Reorganize scanned candidates into year/month buckets for wizard display
    func organizeIntoTimeBuckets() {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())

        // Use the existing allTime candidates as the source
        guard let allTimeData = candidatesByTimeFrame[.allTime] else {
            debugLog("⚠️ No allTime candidates to organize into buckets")
            return
        }

        // Filter out invalid records (Null Island, zero coordinates, etc.)
        var filteredAllTimeData: [String: [DiscoveredRecord]] = [:]
        for (recordType, candidates) in allTimeData {
            let validCandidates = candidates.filter { candidate in
                isValidCandidate(candidate, recordType: recordType)
            }
            if !validCandidates.isEmpty {
                filteredAllTimeData[recordType] = validCandidates
            }
        }

        // Copy to wizard's allTimeCandidates (sorted by extremeness with favorites in top 10 first)
        allTimeCandidates = [:]
        for (recordType, candidates) in filteredAllTimeData {
            allTimeCandidates[recordType] = sortByExtremeness(candidates, recordType: recordType)
        }

        // Build yearly buckets from filtered candidates
        var yearDict: [Int: [String: [DiscoveredRecord]]] = [:]

        for (recordType, candidates) in filteredAllTimeData {
            for candidate in candidates {
                let year = calendar.component(.year, from: candidate.timestamp)
                yearDict[year, default: [:]][recordType, default: []].append(candidate)
            }
        }

        // Sort each year's candidates by extremeness and create buckets
        // Exclude current year since it's covered by monthly buckets
        yearlyBuckets = yearDict.keys.sorted(by: >).compactMap { year in
            guard year != currentYear else { return nil }  // Skip current year
            guard let yearData = yearDict[year] else { return nil }
            var records: [String: [DiscoveredRecord]] = [:]
            for (recordType, candidates) in yearData {
                records[recordType] = sortByExtremeness(candidates, recordType: recordType)
            }
            let bucket = YearBucket(id: year, records: records)
            return bucket.isEmpty ? nil : bucket
        }

        // Build monthly buckets (CURRENT YEAR ONLY)
        var monthDict: [Int: [String: [DiscoveredRecord]]] = [:]

        for (recordType, candidates) in filteredAllTimeData {
            for candidate in candidates {
                let year = calendar.component(.year, from: candidate.timestamp)
                guard year == currentYear else { continue }

                let month = calendar.component(.month, from: candidate.timestamp)
                monthDict[month, default: [:]][recordType, default: []].append(candidate)
            }
        }

        // Sort and create month buckets (1-12 order)
        monthlyBuckets = (1...12).compactMap { month in
            guard let monthData = monthDict[month] else { return nil }
            var sortedRecords: [String: [DiscoveredRecord]] = [:]
            for (recordType, candidates) in monthData {
                sortedRecords[recordType] = sortByExtremeness(candidates, recordType: recordType)
            }
            let bucket = MonthBucket(id: month, year: currentYear, records: sortedRecords)
            return bucket.isEmpty ? nil : bucket
        }

        // Initialize default selections
        initializeDefaultSelections()
    }

    /// Sort candidates by extremeness (most extreme first) with favorites in top 10 moved to front
    /// Used for record candidates (N/S/E/W/Up/FromHome)
    private func sortByExtremeness(_ candidates: [DiscoveredRecord], recordType: String) -> [DiscoveredRecord] {
        guard let type = RecordType.from(string: recordType) else { return candidates }

        // Sort by extremeness (most extreme first)
        let sorted = candidates.sorted { c1, c2 in
            type.shouldReplace(newValue: c1.value, oldValue: c2.value)
        }

        // Move favorites within top 10 to the very front
        let top10 = Array(sorted.prefix(10))
        let favoritesInTop10 = top10.filter { $0.photoAsset.isFavorite }
        let nonFavoritesInTop10 = top10.filter { !$0.photoAsset.isFavorite }
        let rest = Array(sorted.dropFirst(10))

        return favoritesInTop10 + nonFavoritesInTop10 + rest
    }

    /// Sort PHAssets by date with favorites prioritized within each year
    /// Order: oldest year first, favorites first within each year, then by date (oldest to newest)
    /// Used for region photo assets
    private func sortAssetsByDateWithFavoritesFirstByYear(_ assets: [PHAsset]) -> [PHAsset] {
        let calendar = Calendar.current

        // Group assets by year
        var byYear: [Int: [PHAsset]] = [:]
        for asset in assets {
            guard let date = asset.creationDate else {
                byYear[0, default: []].append(asset)  // Unknown year goes to bucket 0
                continue
            }
            let year = calendar.component(.year, from: date)
            byYear[year, default: []].append(asset)
        }

        // Sort years oldest to newest
        let sortedYears = byYear.keys.sorted()

        // Build result: for each year, favorites first (by date), then non-favorites (by date)
        var result: [PHAsset] = []
        for year in sortedYears {
            guard let yearAssets = byYear[year] else { continue }

            // Within each year: favorites first (by date), then non-favorites (by date)
            let favorites = yearAssets
                .filter { $0.isFavorite }
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            let nonFavorites = yearAssets
                .filter { !$0.isFavorite }
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

            result.append(contentsOf: favorites)
            result.append(contentsOf: nonFavorites)
        }

        return result
    }

    /// Check if a candidate has valid location data (filters Null Island and unrealistic altitudes)
    private func isValidCandidate(_ candidate: DiscoveredRecord, recordType: String) -> Bool {
        let lat = candidate.coordinate.latitude
        let lon = candidate.coordinate.longitude
        let alt = candidate.altitude

        // Use shared validation that checks Null Island (with altitude if available)
        // and unrealistic altitude values
        let validationResult = validateLocation(latitude: lat, longitude: lon, altitude: alt)

        switch validationResult {
        case .valid:
            return true
        case .nullIsland:
            debugLog("⚠️ Filtering Null Island candidate for \(recordType)")
            return false
        case .unrealisticAltitude(let meters):
            debugLog("⚠️ Filtering unrealistic altitude (\(meters)m) candidate for \(recordType)")
            return false
        }
    }

    /// Initialize selections - pre-select photos that match existing records, otherwise default to index 0
    /// Also tracks which records already exist (for "NEW" badge) and initial selections (for modification tracking)
    private func initializeDefaultSelections() {
        wizardSelections = WizardSelection()

        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let currentMonth = calendar.component(.month, from: Date())

        debugLog("🔍 initializeDefaultSelections: Starting with \(allTimeCandidates.count) allTime types, \(yearlyBuckets.count) yearly buckets, \(monthlyBuckets.count) monthly buckets")

        // All-time: try to match existing record photos, otherwise select index 0
        // Respect previously skipped records
        for recordType in allTimeCandidates.keys {
            if let candidates = allTimeCandidates[recordType], !candidates.isEmpty {
                let selKey = WizardSelection.selectionKey(timeFrame: "allTime", recordType: recordType)

                // Check if this record was previously skipped by user
                // Use candidates.count as skip index (matches UI's skipIndex convention)
                if SettingsManager.shared.isWizardRecordSkipped(timeFrame: "allTime", recordType: recordType) {
                    let skipIndex = candidates.count
                    wizardSelections.allTime[recordType] = skipIndex
                    wizardSelections.initialSelections[selKey] = skipIndex
                    debugLog("🔍 AllTime \(recordType): Previously skipped by user (index=\(skipIndex))")
                    continue
                }

                let existingRecord = RecordManager.shared.getRecord(type: recordType, timeFrame: .allTime)
                let matchIndex = findMatchingCandidateIndex(candidates: candidates, existingRecord: existingRecord)
                wizardSelections.allTime[recordType] = matchIndex

                if let existing = existingRecord {
                    debugLog("🔍 AllTime \(recordType): existing photo=\(existing.photoAssetIdentifier ?? "nil"), matchIndex=\(matchIndex)")
                }

                // Track if record exists
                if existingRecord != nil {
                    wizardSelections.existingRecords.insert(selKey)
                }
                wizardSelections.initialSelections[selKey] = matchIndex
            }
        }

        // Yearly: try to match existing record photos for each year
        // Respect previously skipped records
        for bucket in yearlyBuckets {
            var yearSelections: [String: Int] = [:]
            for recordType in bucket.availableRecordTypes {
                if let candidates = bucket.records[recordType], !candidates.isEmpty {
                    let selKey = WizardSelection.selectionKey(timeFrame: "\(bucket.id)", recordType: recordType)

                    // Check if this record was previously skipped by user
                    // Use candidates.count as skip index (matches UI's skipIndex convention)
                    if SettingsManager.shared.isWizardRecordSkipped(timeFrame: "\(bucket.id)", recordType: recordType) {
                        let skipIndex = candidates.count
                        yearSelections[recordType] = skipIndex
                        wizardSelections.initialSelections[selKey] = skipIndex
                        debugLog("🔍 Year \(bucket.id) \(recordType): Previously skipped by user (index=\(skipIndex))")
                        continue
                    }

                    // For current year, check RecordManager; for past years, check history
                    let existingRecord: RecordDetail?
                    let hasExistingRecord: Bool

                    if bucket.id == currentYear {
                        existingRecord = RecordManager.shared.getRecord(type: recordType, timeFrame: .year)
                        hasExistingRecord = existingRecord != nil
                    } else {
                        // Check history for past years
                        existingRecord = RecordHistoryManager.shared.getBestRecord(
                            type: recordType,
                            year: bucket.id
                        )
                        hasExistingRecord = existingRecord != nil
                    }

                    let matchIndex = findMatchingCandidateIndex(candidates: candidates, existingRecord: existingRecord)
                    yearSelections[recordType] = matchIndex

                    if let existing = existingRecord {
                        debugLog("🔍 Year \(bucket.id) \(recordType): existing photo=\(existing.photoAssetIdentifier ?? "nil"), matchIndex=\(matchIndex), candidates=\(candidates.count)")
                    }

                    // Track if record exists
                    if hasExistingRecord {
                        wizardSelections.existingRecords.insert(selKey)
                    }
                    wizardSelections.initialSelections[selKey] = matchIndex
                }
            }
            wizardSelections.yearly[bucket.id] = yearSelections
        }

        // Monthly: try to match existing record photos for each month
        // Respect previously skipped records
        for bucket in monthlyBuckets {
            let key = WizardSelection.monthKey(year: bucket.year, month: bucket.id)
            var monthSelections: [String: Int] = [:]
            for recordType in bucket.availableRecordTypes {
                if let candidates = bucket.records[recordType], !candidates.isEmpty {
                    let selKey = WizardSelection.selectionKey(timeFrame: key, recordType: recordType)

                    // Check if this record was previously skipped by user
                    // Use candidates.count as skip index (matches UI's skipIndex convention)
                    if SettingsManager.shared.isWizardRecordSkipped(timeFrame: key, recordType: recordType) {
                        let skipIndex = candidates.count
                        monthSelections[recordType] = skipIndex
                        wizardSelections.initialSelections[selKey] = skipIndex
                        debugLog("🔍 Month \(key) \(recordType): Previously skipped by user (index=\(skipIndex))")
                        continue
                    }

                    // For current month, check RecordManager; for past months, check history
                    let existingRecord: RecordDetail?
                    let hasExistingRecord: Bool

                    if bucket.id == currentMonth && bucket.year == currentYear {
                        existingRecord = RecordManager.shared.getRecord(type: recordType, timeFrame: .month)
                        hasExistingRecord = existingRecord != nil
                    } else {
                        // Check history for past months
                        existingRecord = RecordHistoryManager.shared.getBestRecord(
                            type: recordType,
                            year: bucket.year,
                            month: bucket.id
                        )
                        hasExistingRecord = existingRecord != nil
                    }

                    let matchIndex = findMatchingCandidateIndex(candidates: candidates, existingRecord: existingRecord)
                    monthSelections[recordType] = matchIndex

                    if let existing = existingRecord {
                        debugLog("🔍 Month \(key) \(recordType): existing photo=\(existing.photoAssetIdentifier ?? "nil"), matchIndex=\(matchIndex), candidates=\(candidates.count)")
                    }

                    // Track if record exists
                    if hasExistingRecord {
                        wizardSelections.existingRecords.insert(selKey)
                    }
                    wizardSelections.initialSelections[selKey] = matchIndex
                }
            }
            wizardSelections.monthly[key] = monthSelections
        }

        debugLog("🔍 initializeDefaultSelections: Done. AllTime selections=\(wizardSelections.allTime.count), Yearly=\(wizardSelections.yearly.count), Monthly=\(wizardSelections.monthly.count)")
    }

    /// Find the index of a candidate that matches an existing record's photo
    /// Returns 0 if no match found (default to most extreme)
    private func findMatchingCandidateIndex(candidates: [DiscoveredRecord], existingRecord: RecordDetail?) -> Int {
        guard let existing = existingRecord else {
            debugLog("⚠️ findMatchingCandidateIndex: No existing record")
            return 0
        }

        // Try to match by photo asset identifier
        if let existingAssetId = existing.photoAssetIdentifier {
            for (index, candidate) in candidates.enumerated() {
                if candidate.photoAsset.localIdentifier == existingAssetId {
                    return index
                }
            }
            debugLog("⚠️ findMatchingCandidateIndex: Photo \(existingAssetId) not found in \(candidates.count) candidates for \(existing.recordType)")
        } else {
            debugLog("⚠️ findMatchingCandidateIndex: No photoAssetIdentifier for \(existing.recordType)")
        }

        // Try to match by cloud identifier
        if let existingCloudId = existing.photoCloudIdentifier {
            for (index, candidate) in candidates.enumerated() {
                let cloudId = PHPhotoLibrary.cloudIdentifier(for: candidate.photoAsset)
                if cloudId == existingCloudId {
                    debugLog("✅ findMatchingCandidateIndex: Found by cloud ID at index \(index)")
                    return index
                }
            }
            debugLog("⚠️ findMatchingCandidateIndex: Cloud ID \(existingCloudId) not found either")
        }

        // No match found, default to most extreme (index 0)
        debugLog("⚠️ findMatchingCandidateIndex: Defaulting to index 0 for \(existing.recordType)")
        return 0
    }

    /// Update selection for all-time record
    func updateAllTimeSelection(recordType: String, index: Int) {
        objectWillChange.send()
        wizardSelections.allTime[recordType] = index
    }

    /// Update selection for yearly record
    func updateYearlySelection(year: Int, recordType: String, index: Int) {
        objectWillChange.send()
        wizardSelections.yearly[year, default: [:]][recordType] = index
    }

    /// Update selection for monthly record
    func updateMonthlySelection(year: Int, month: Int, recordType: String, index: Int) {
        objectWillChange.send()
        let key = WizardSelection.monthKey(year: year, month: month)
        wizardSelections.monthly[key, default: [:]][recordType] = index
    }

    /// Build confirmed records from wizard selections for import
    /// - Existing records that weren't modified are skipped (no re-import)
    /// - Existing records that were modified are included for import
    /// - New records are included for import (unless skipped)
    /// - Existing records that were skipped are added to recordsToDelete
    func buildConfirmedRecordsFromSelections() {
        confirmedRecords = []
        recordsToDelete = []

        debugLog("📦 buildConfirmedRecordsFromSelections: Starting...")

        // All-time selections
        for (recordType, index) in wizardSelections.allTime {
            guard let candidates = allTimeCandidates[recordType] else {
                debugLog("📦 AllTime \(recordType): No candidates found")
                continue
            }
            let exists = wizardSelections.recordExists(timeFrame: "allTime", recordType: recordType)
            let modified = wizardSelections.isModified(timeFrame: "allTime", recordType: recordType)
            let isSkipped = index < 0 || index >= candidates.count

            debugLog("📦 AllTime \(recordType): index=\(index), exists=\(exists), modified=\(modified), skipped=\(isSkipped), candidateCount=\(candidates.count)")

            if isSkipped {
                // User chose to skip this record
                if exists {
                    // Existing record skipped = delete it
                    recordsToDelete.append(RecordToDelete(
                        recordType: recordType,
                        timeFrame: .allTime,
                        year: nil,
                        month: nil
                    ))
                    debugLog("📦 AllTime \(recordType): Marked for deletion (skipped existing)")
                }
                // New record skipped = just don't import it
            } else if exists && !modified {
                // Existing record not modified = skip re-import
                debugLog("📦 AllTime \(recordType): SKIPPED (exists && !modified)")
                continue
            } else {
                // Either new record, or existing record that was modified
                var record = candidates[index]
                record.beatsTimeFrames = [.allTime]
                confirmedRecords.append(record)
                debugLog("📦 AllTime \(recordType): IMPORTING photo=\(record.photoAsset.localIdentifier), value=\(record.value)")
            }
        }

        // Yearly selections
        for (year, selections) in wizardSelections.yearly {
            guard let bucket = yearlyBuckets.first(where: { $0.id == year }) else { continue }

            for (recordType, index) in selections {
                guard let candidates = bucket.records[recordType] else { continue }
                let exists = wizardSelections.recordExists(timeFrame: "\(year)", recordType: recordType)
                let modified = wizardSelections.isModified(timeFrame: "\(year)", recordType: recordType)
                let isSkipped = index < 0 || index >= candidates.count

                // Only log years with actual selections that might be interesting
                if modified || !exists || isSkipped {
                    debugLog("📦 Year \(year) \(recordType): index=\(index), exists=\(exists), modified=\(modified), skipped=\(isSkipped)")
                }

                if isSkipped {
                    if exists {
                        recordsToDelete.append(RecordToDelete(
                            recordType: recordType,
                            timeFrame: .year,
                            year: year,
                            month: nil
                        ))
                        debugLog("📦 Year \(year) \(recordType): Marked for deletion")
                    }
                } else if exists && !modified {
                    // Existing record not modified = skip re-import (no log to reduce noise)
                    continue
                } else {
                    var record = candidates[index]
                    record.beatsTimeFrames = [.year]
                    confirmedRecords.append(record)
                    debugLog("📦 Year \(year) \(recordType): IMPORTING photo=\(record.photoAsset.localIdentifier)")
                }
            }
        }

        // Monthly selections
        let currentYear = Calendar.current.component(.year, from: Date())
        for (monthKey, selections) in wizardSelections.monthly {
            let components = monthKey.split(separator: "-")
            guard components.count == 2,
                  let month = Int(components[1]),
                  let bucket = monthlyBuckets.first(where: { $0.id == month }) else { continue }

            for (recordType, index) in selections {
                guard let candidates = bucket.records[recordType] else { continue }
                let exists = wizardSelections.recordExists(timeFrame: monthKey, recordType: recordType)
                let modified = wizardSelections.isModified(timeFrame: monthKey, recordType: recordType)
                let isSkipped = index < 0 || index >= candidates.count

                if isSkipped {
                    if exists {
                        recordsToDelete.append(RecordToDelete(
                            recordType: recordType,
                            timeFrame: .month,
                            year: currentYear,
                            month: month
                        ))
                    }
                } else if exists && !modified {
                    continue
                } else {
                    var record = candidates[index]
                    record.beatsTimeFrames = [.month]
                    confirmedRecords.append(record)
                }
            }
        }
    }

    /// Check if wizard has any records to display
    var hasWizardRecords: Bool {
        !allTimeCandidates.isEmpty || !yearlyBuckets.isEmpty || !monthlyBuckets.isEmpty
    }

    /// Reset wizard state
    func resetWizardState() {
        allTimeCandidates = [:]
        yearlyBuckets = []
        monthlyBuckets = []
        wizardSelections = WizardSelection()
        currentWizardStep = .allTime
        isWizardMode = false
        recordsToDelete = []
    }

    /// Persist user's skip choices to SettingsManager for future wizard runs
    private func persistSkippedRecordChoices() {
        var skippedKeys: Set<String> = []
        var importedKeys: Set<String> = []

        // Check all-time selections
        for (recordType, index) in wizardSelections.allTime {
            let key = WizardSelection.selectionKey(timeFrame: "allTime", recordType: recordType)
            if let candidates = allTimeCandidates[recordType] {
                let isSkipped = index < 0 || index >= candidates.count
                if isSkipped {
                    skippedKeys.insert(key)
                } else {
                    importedKeys.insert(key)
                }
            }
        }

        // Check yearly selections
        for (year, selections) in wizardSelections.yearly {
            for (recordType, index) in selections {
                let key = WizardSelection.selectionKey(timeFrame: "\(year)", recordType: recordType)
                if let bucket = yearlyBuckets.first(where: { $0.id == year }),
                   let candidates = bucket.records[recordType] {
                    let isSkipped = index < 0 || index >= candidates.count
                    if isSkipped {
                        skippedKeys.insert(key)
                    } else {
                        importedKeys.insert(key)
                    }
                }
            }
        }

        // Check monthly selections
        for (monthKey, selections) in wizardSelections.monthly {
            for (recordType, index) in selections {
                let key = WizardSelection.selectionKey(timeFrame: monthKey, recordType: recordType)
                let components = monthKey.split(separator: "-")
                if components.count == 2,
                   let month = Int(components[1]),
                   let bucket = monthlyBuckets.first(where: { $0.id == month }),
                   let candidates = bucket.records[recordType] {
                    let isSkipped = index < 0 || index >= candidates.count
                    if isSkipped {
                        skippedKeys.insert(key)
                    } else {
                        importedKeys.insert(key)
                    }
                }
            }
        }

        // Update settings
        SettingsManager.shared.updateSkippedRecordsFromWizard(skippedKeys: skippedKeys, importedKeys: importedKeys)
        debugLog("📦 Persisted skip choices: \(skippedKeys.count) skipped, \(importedKeys.count) imported")
    }

    // MARK: - Monthly Historical Records for Statistics

    /// Create RecordHistoryEntry records for each month's extremes
    /// This enables the Stats tab to show location names when dragging over chart bars
    /// - Returns: Number of records created
    private func createMonthlyHistoricalRecords(
        northCandidates: [PhotoCandidate],
        southCandidates: [PhotoCandidate],
        eastCandidates: [PhotoCandidate],
        westCandidates: [PhotoCandidate],
        upCandidates: [PhotoCandidate],
        fromHomeCandidates: [PhotoCandidate]
    ) async -> Int {
        let calendar = Calendar.current
        var recordsCreated = 0

        // Helper to group candidates by year-month and find the extreme for each
        func findMonthlyExtremes(
            _ candidates: [PhotoCandidate],
            ascending: Bool
        ) -> [String: PhotoCandidate] {
            var byMonth: [String: [PhotoCandidate]] = [:]

            for candidate in candidates {
                guard let date = candidate.asset.creationDate else { continue }
                let year = calendar.component(.year, from: date)
                let month = calendar.component(.month, from: date)
                let key = "\(year)-\(String(format: "%02d", month))"
                byMonth[key, default: []].append(candidate)
            }

            // Find extreme for each month
            var extremes: [String: PhotoCandidate] = [:]
            for (key, monthCandidates) in byMonth {
                if ascending {
                    if let extreme = monthCandidates.min(by: { $0.value < $1.value }) {
                        extremes[key] = extreme
                    }
                } else {
                    if let extreme = monthCandidates.max(by: { $0.value < $1.value }) {
                        extremes[key] = extreme
                    }
                }
            }
            return extremes
        }

        // Find monthly extremes for each record type
        let recordTypes: [(type: String, candidates: [PhotoCandidate], ascending: Bool)] = [
            (RecordType.north.rawValue, northCandidates, false),  // Highest latitude
            (RecordType.south.rawValue, southCandidates, true),   // Lowest latitude
            (RecordType.east.rawValue, eastCandidates, false),    // Highest longitude
            (RecordType.west.rawValue, westCandidates, true),     // Lowest longitude
            (RecordType.up.rawValue, upCandidates, false),        // Highest altitude
            (RecordType.fromHome.rawValue, fromHomeCandidates, false)  // Furthest distance
        ]

        for (recordType, candidates, ascending) in recordTypes {
            let monthlyExtremes = findMonthlyExtremes(candidates, ascending: ascending)

            for (_, candidate) in monthlyExtremes {
                guard let timestamp = candidate.asset.creationDate else { continue }

                // Check if a record already exists for this type/month
                let year = calendar.component(.year, from: timestamp)
                let month = calendar.component(.month, from: timestamp)

                if RecordHistoryManager.shared.getBestRecord(type: recordType, year: year, month: month) != nil {
                    // Record already exists for this month, skip
                    continue
                }

                // Get cloud identifier for cross-device access
                let photoCloudIdentifier = PHPhotoLibrary.cloudIdentifier(for: candidate.asset)

                // Create the record
                let detail = RecordDetail(
                    value: candidate.value,
                    timestamp: timestamp,
                    coordinate: candidate.location.coordinate,
                    altitude: candidate.location.altitude,
                    locationName: nil,  // Will be geocoded by BackgroundGeocoder
                    recordType: recordType,
                    timeFrame: .month,
                    photoAssetIdentifier: candidate.asset.localIdentifier,
                    photoCloudIdentifier: photoCloudIdentifier
                )

                _ = await MainActor.run {
                    RecordHistoryManager.shared.addRecord(recordType: recordType, detail: detail)
                }
                recordsCreated += 1
            }
        }

        return recordsCreated
    }

    // MARK: - Region Discovery

    /// Convert collected regionPhotoMap to discoveredCountries and discoveredStates arrays
    private func buildDiscoveredRegions() {
        var countries: [DiscoveredRegion] = []
        var states: [DiscoveredRegion] = []

        // Get existing region records for photo matching
        let existingStates = RegionTrackingManager.shared.visitedStates
        let existingCountries = RegionTrackingManager.shared.visitedCountries

        for (code, data) in regionPhotoMap {
            // Sort photos by year, favorites first within each year, oldest to newest
            let sortedAssets = sortAssetsByDateWithFavoritesFirstByYear(data.assets)

            // Find index of existing photo if this region already exists
            let selectedIndex = findExistingRegionPhotoIndex(
                regionCode: code,
                regionType: data.info.type,
                sortedAssets: sortedAssets,
                existingStates: existingStates,
                existingCountries: existingCountries
            )

            var region = DiscoveredRegion(
                regionCode: code,
                regionName: data.info.name,
                regionType: data.info.type,
                continent: data.info.continent,
                photoAssets: sortedAssets,
                confirmed: true  // Default to selected
            )
            region.selectedPhotoIndex = selectedIndex

            switch data.info.type {
            case .state:
                states.append(region)
            case .country:
                countries.append(region)
            }
        }

        // Sort by photo count descending (most photos first)
        discoveredCountries = countries.sorted { $0.photoCount > $1.photoCount }
        discoveredStates = states.sorted { $0.photoCount > $1.photoCount }

        debugLog("📍 PhotoLibraryScanner: Discovered \(discoveredCountries.count) countries, \(discoveredStates.count) states")
    }

    /// Find the index of an existing region's photo in the sorted assets array
    /// Returns 0 if no match found (default to first photo)
    private func findExistingRegionPhotoIndex(
        regionCode: String,
        regionType: RegionType,
        sortedAssets: [PHAsset],
        existingStates: [RecordDetail],
        existingCountries: [RecordDetail]
    ) -> Int {
        // Get the existing record for this region
        let existingRecords = regionType == .state ? existingStates : existingCountries
        guard let existing = existingRecords.first(where: { $0.regionCode == regionCode }) else {
            return 0  // No existing record
        }

        // Try to match by photo asset identifier
        if let existingAssetId = existing.photoAssetIdentifier {
            for (index, asset) in sortedAssets.enumerated() {
                if asset.localIdentifier == existingAssetId {
                    debugLog("📍 Found existing photo match for \(regionCode) at index \(index)")
                    return index
                }
            }
        }

        // Try to match by cloud identifier
        if let existingCloudId = existing.photoCloudIdentifier {
            for (index, asset) in sortedAssets.enumerated() {
                let cloudId = PHPhotoLibrary.cloudIdentifier(for: asset)
                if cloudId == existingCloudId {
                    debugLog("📍 Found existing cloud ID match for \(regionCode) at index \(index)")
                    return index
                }
            }
        }

        // No match found, default to first photo
        return 0
    }

    /// Check if there are any discovered regions pending confirmation
    var hasDiscoveredRegions: Bool {
        !discoveredCountries.isEmpty || !discoveredStates.isEmpty
    }

    /// Confirm selected regions and record them
    func confirmDiscoveredRegions() {
        let confirmedCountries = discoveredCountries.filter { $0.confirmed }
        let confirmedStates = discoveredStates.filter { $0.confirmed }

        Task { @MainActor in
            RegionTrackingManager.shared.recordConfirmedRegions(confirmedCountries + confirmedStates)
        }

        debugLog("📍 Confirmed \(confirmedCountries.count) countries, \(confirmedStates.count) states")
    }

    // MARK: - Daily Record Helpers

    /// Update daily records for a photo location (called for current month photos only)
    @MainActor
    private func updateDailyRecordsForPhoto(location: CLLocation, date: Date) {
        RecordHistoryManager.shared.updateAllDailyRecords(
            location: location,
            date: date,
            homeCoordinate: SettingsManager.shared.homeCoordinate
        )
    }
}
