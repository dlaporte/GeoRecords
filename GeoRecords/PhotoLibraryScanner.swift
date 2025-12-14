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

    var title: String {
        switch self {
        case .allTime: return "All-Time Records"
        case .yearly: return "Yearly Records"
        case .monthly: return "Monthly Records"
        }
    }

    var shortTitle: String {
        switch self {
        case .allTime: return "All Years"
        case .yearly: return "Past Years"
        case .monthly: return "This Year"
        }
    }

    var previousStep: ImportWizardStep? {
        switch self {
        case .allTime: return nil
        case .yearly: return .allTime
        case .monthly: return .yearly
        }
    }

    var nextStep: ImportWizardStep? {
        switch self {
        case .allTime: return .yearly
        case .yearly: return .monthly
        case .monthly: return nil
        }
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

    static func monthKey(year: Int, month: Int) -> String {
        return "\(year)-\(String(format: "%02d", month))"
    }
}

@MainActor
class PhotoLibraryScanner: ObservableObject {
    @Published var isScanning = false
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

        // Collect ALL candidates (not just extremes)
        var northCandidates: [PhotoCandidate] = []
        var southCandidates: [PhotoCandidate] = []
        var eastCandidates: [PhotoCandidate] = []
        var westCandidates: [PhotoCandidate] = []
        var upCandidates: [PhotoCandidate] = []
        var fromHomeCandidates: [PhotoCandidate] = []

        // Scan all photos asynchronously in batches
        let batchSize = photoScanBatchSize
        let count = allPhotos.count

        for batchStart in stride(from: 0, to: count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, count)

            // Process batch off main thread
            await Task.detached {
                for index in batchStart..<batchEnd {
                    let asset = allPhotos.object(at: index)

                    await MainActor.run {
                        self.scannedPhotos = index + 1
                        self.progress = Double(index + 1) / Double(self.totalPhotos)
                    }

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

                    await MainActor.run {
                        self.photosWithLocation += 1
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
                }
            }.value

            // Brief yield to UI
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }

        // Daily statistics are recorded during import (not scan)
        // This ensures only user-selected records affect the charts

        // Get current month and year boundaries
        let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

        // Sort candidates by extremeness
        northCandidates.sort { $0.value > $1.value }  // Highest latitude first
        southCandidates.sort { $0.value < $1.value }  // Lowest latitude first
        eastCandidates.sort { $0.value > $1.value }  // Highest longitude first
        westCandidates.sort { $0.value < $1.value }  // Lowest longitude first
        upCandidates.sort { $0.value > $1.value }  // Highest altitude first
        fromHomeCandidates.sort { $0.value > $1.value }  // Furthest distance first

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

        isScanning = false

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
            if photosWithLocation == 0 {
                errorMessage = "No photos with location data found in your library"
            } else {
                errorMessage = "No records found that would beat your current records"
            }
        } else {
            // Organize into wizard buckets and start wizard mode
            organizeIntoTimeBuckets()
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

        // Reset import state
        await MainActor.run {
            isImporting = true
            importProgress = (0, selectedRecords.count)
        }

        // Block ALL alerts during import - this is foolproof
        await MainActor.run {
            RecordManager.shared.blockAlertsDuringImport(block: true)
        }

        var successCount = 0

        for (index, record) in selectedRecords.enumerated() {
            // Update progress
            await MainActor.run {
                importProgress = (index, selectedRecords.count)
            }

            // Record daily statistics ONLY for this specific record type
            // This prevents a "Furthest North" import from also recording its altitude
            let location = CLLocation(latitude: record.coordinate.latitude, longitude: record.coordinate.longitude)
            await MainActor.run {
                let homeCoord = SettingsManager.shared.homeCoordinate
                DailyStatisticManager.shared.recordForRecordType(
                    record.recordType,
                    location: location,
                    altitude: record.altitude,
                    date: record.timestamp,
                    homeCoordinate: homeCoord,
                    batchMode: true
                )
            }

            // Get photo asset identifier (reference to Apple Photos library)
            let photoAssetIdentifier = record.photoAsset.localIdentifier
            debugLog("📸 Photo asset identifier: \(photoAssetIdentifier)")
            debugLog("📅 Photo timestamp (EXIF): \(record.timestamp)")

            // Use the timeframes that were determined during scanning
            let timeFrames = record.beatsTimeFrames
            debugLog("📅 Importing \(record.recordType) for timeframes: \(timeFrames.map { $0.rawValue }.joined(separator: ", "))")

            // Create records for each applicable timeframe
            let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

            for timeFrame in timeFrames {
                let detail = RecordDetail(
                    value: record.value,
                    timestamp: record.timestamp,
                    coordinate: record.coordinate,
                    altitude: record.altitude,
                    locationName: record.locationName,
                    recordType: record.recordType,
                    timeFrame: timeFrame,
                    photoAssetIdentifier: photoAssetIdentifier
                )

                // Always add to history (for stats and historical tracking)
                await MainActor.run {
                    RecordHistoryManager.shared.addRecord(recordType: record.recordType, detail: detail)
                }

                // Only update RecordManager if record belongs to CURRENT timeframe period
                // RecordManager tracks current records, not historical ones
                let shouldUpdateRecordManager: Bool
                switch timeFrame {
                case .allTime:
                    shouldUpdateRecordManager = true
                case .year:
                    shouldUpdateRecordManager = record.timestamp >= startOfYear
                case .month:
                    shouldUpdateRecordManager = record.timestamp >= startOfMonth
                }

                if shouldUpdateRecordManager {
                    _ = await MainActor.run {
                        RecordManager.shared.updateRecordIfBetter(recordType: record.recordType, detail: detail, timeFrame: timeFrame)
                    }
                }
            }
            successCount += 1
        }

        await MainActor.run {
            // Flush batched daily statistics
            DailyStatisticManager.shared.flushBatchChanges()
            debugLog("📊 Daily statistics recorded for \(successCount) imported records")

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
            completion(successCount)

            // Start background geocoding for any imported records missing location names
            Task {
                await BackgroundGeocoder.shared.geocodeMissingLocations()
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

        // Copy to wizard's allTimeCandidates
        allTimeCandidates = filteredAllTimeData

        // Build yearly buckets from filtered candidates
        var yearDict: [Int: [String: [DiscoveredRecord]]] = [:]

        for (recordType, candidates) in filteredAllTimeData {
            for candidate in candidates {
                let year = calendar.component(.year, from: candidate.timestamp)
                yearDict[year, default: [:]][recordType, default: []].append(candidate)
            }
        }

        // Sort each year's candidates by extremeness and create buckets
        yearlyBuckets = yearDict.keys.sorted(by: >).compactMap { year in
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

    /// Sort candidates by extremeness for a given record type
    /// Favorites within threshold of the best value are prioritized to the front
    private func sortByExtremeness(_ candidates: [DiscoveredRecord], recordType: String) -> [DiscoveredRecord] {
        guard let type = RecordType.from(string: recordType) else { return candidates }

        // First, sort by extremeness
        let sorted = candidates.sorted { c1, c2 in
            type.shouldReplace(newValue: c1.value, oldValue: c2.value)
        }

        guard let bestValue = sorted.first?.value else { return sorted }

        // Get threshold for this record type
        let threshold = getThresholdForFavorites(recordType: recordType)

        // Partition into favorites-within-threshold and others
        var favoritesInThreshold: [DiscoveredRecord] = []
        var others: [DiscoveredRecord] = []

        for candidate in sorted {
            let isWithinThreshold = abs(candidate.value - bestValue) <= threshold
            if candidate.photoAsset.isFavorite && isWithinThreshold {
                favoritesInThreshold.append(candidate)
            } else {
                others.append(candidate)
            }
        }

        // Return favorites first (maintaining their relative order), then others
        return favoritesInThreshold + others
    }

    /// Get the threshold for prioritizing favorites for a given record type
    private func getThresholdForFavorites(recordType: String) -> Double {
        let settings = SettingsManager.shared

        switch recordType {
        case RecordType.north.rawValue, RecordType.south.rawValue:
            return settings.minLatitudeDelta
        case RecordType.east.rawValue, RecordType.west.rawValue:
            return settings.minLongitudeDelta
        case RecordType.up.rawValue:
            // 50 feet in meters
            return 50.0 * 0.3048
        case RecordType.fromHome.rawValue:
            return settings.minDistanceDeltaMeters
        default:
            return 0
        }
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

    /// Initialize default selections (index 0 = most extreme for all)
    private func initializeDefaultSelections() {
        wizardSelections = WizardSelection()

        // All-time: select index 0 for each record type that has candidates
        for recordType in allTimeCandidates.keys {
            if let candidates = allTimeCandidates[recordType], !candidates.isEmpty {
                wizardSelections.allTime[recordType] = 0
            }
        }

        // Yearly: select index 0 for each year/recordType with candidates
        for bucket in yearlyBuckets {
            var yearSelections: [String: Int] = [:]
            for recordType in bucket.availableRecordTypes {
                yearSelections[recordType] = 0
            }
            wizardSelections.yearly[bucket.id] = yearSelections
        }

        // Monthly: select index 0 for each month/recordType with candidates
        for bucket in monthlyBuckets {
            let key = WizardSelection.monthKey(year: bucket.year, month: bucket.id)
            var monthSelections: [String: Int] = [:]
            for recordType in bucket.availableRecordTypes {
                monthSelections[recordType] = 0
            }
            wizardSelections.monthly[key] = monthSelections
        }

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
    /// Skipped records (index >= available candidates) are not included
    func buildConfirmedRecordsFromSelections() {
        confirmedRecords = []

        // All-time selections
        for (recordType, index) in wizardSelections.allTime {
            guard let candidates = allTimeCandidates[recordType] else { continue }
            // Skip if index equals candidates.count (skip position) or is invalid
            guard index >= 0 && index < candidates.count else { continue }
            var record = candidates[index]
            record.beatsTimeFrames = [.allTime]
            confirmedRecords.append(record)
        }

        // Yearly selections
        for (year, selections) in wizardSelections.yearly {
            guard let bucket = yearlyBuckets.first(where: { $0.id == year }) else { continue }

            for (recordType, index) in selections {
                guard let candidates = bucket.records[recordType] else { continue }
                // Skip if index equals candidates.count (skip position) or is invalid
                guard index >= 0 && index < candidates.count else { continue }
                var record = candidates[index]
                record.beatsTimeFrames = [.year]
                confirmedRecords.append(record)
            }
        }

        // Monthly selections
        for (monthKey, selections) in wizardSelections.monthly {
            let components = monthKey.split(separator: "-")
            guard components.count == 2,
                  let month = Int(components[1]),
                  let bucket = monthlyBuckets.first(where: { $0.id == month }) else { continue }

            for (recordType, index) in selections {
                guard let candidates = bucket.records[recordType] else { continue }
                // Skip if index equals candidates.count (skip position) or is invalid
                guard index >= 0 && index < candidates.count else { continue }
                var record = candidates[index]
                record.beatsTimeFrames = [.month]
                confirmedRecords.append(record)
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
    }
}
