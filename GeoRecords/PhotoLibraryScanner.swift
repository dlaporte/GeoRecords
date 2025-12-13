import Foundation
import Photos
import CoreLocation
import UIKit

// MARK: - Open-Elevation API

/// Fetches terrain elevation for coordinates using Open-Elevation API
private func fetchTerrainElevations(for coordinates: [(lat: Double, lon: Double)]) async -> [Double?] {
    guard !coordinates.isEmpty else { return [] }

    // Build the API request (batch up to 100 at a time)
    let locations = coordinates.map { "{\"latitude\": \($0.lat), \"longitude\": \($0.lon)}" }.joined(separator: ",")
    let jsonBody = "{\"locations\": [\(locations)]}"

    guard let url = URL(string: "https://api.open-elevation.com/api/v1/lookup"),
          let bodyData = jsonBody.data(using: .utf8) else {
        return Array(repeating: nil, count: coordinates.count)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = bodyData
    request.timeoutInterval = 30

    do {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            debugLog("⛰️ Elevation API returned non-200 status")
            return Array(repeating: nil, count: coordinates.count)
        }

        // Parse response: {"results": [{"latitude": x, "longitude": y, "elevation": z}, ...]}
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]] {
            return results.map { $0["elevation"] as? Double }
        }
    } catch {
        debugLog("⛰️ Elevation API error: \(error.localizedDescription)")
    }

    return Array(repeating: nil, count: coordinates.count)
}

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

    // Three-phase confirmation flow
    @Published var currentTimeFrame: TimeFrame? = nil  // Current phase: month, year, or allTime
    @Published var currentRecordTypeIndex = 0  // Index into recordTypes array
    @Published var isConfirming = false

    private let recordTypes = RecordType.allTypeStrings

    // Candidates organized by timeframe, then record type (sorted by extremeness)
    private var candidatesByTimeFrame: [TimeFrame: [String: [DiscoveredRecord]]] = [:]
    private var currentCandidateIndices: [String: Int] = [:]  // Key format: "timeFrame_recordType"
    var confirmedRecords: [DiscoveredRecord] = []  // All confirmed records for import

    func requestPhotoLibraryAccess(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
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
        var northCandidates: [(value: Double, asset: PHAsset, location: CLLocation)] = []
        var southCandidates: [(value: Double, asset: PHAsset, location: CLLocation)] = []
        var eastCandidates: [(value: Double, asset: PHAsset, location: CLLocation)] = []
        var westCandidates: [(value: Double, asset: PHAsset, location: CLLocation)] = []
        var upCandidates: [(value: Double, asset: PHAsset, location: CLLocation)] = []
        var downCandidates: [(value: Double, asset: PHAsset, location: CLLocation)] = []
        var fromHomeCandidates: [(value: Double, asset: PHAsset, location: CLLocation)] = []

        // Scan all photos asynchronously in batches
        let batchSize = photoScanBatchSize
        let count = allPhotos.count

        // Collect all locations for batch processing of daily statistics
        var allLocationsWithDates: [(location: CLLocation, date: Date)] = []

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
                          let timestamp = asset.creationDate else { continue }

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

                    // Record this location for daily statistics (ALL geotagged photos)
                    allLocationsWithDates.append((location, timestamp))

                    // Collect ALL candidates for each direction
                    northCandidates.append((lat, asset, location))
                    southCandidates.append((lat, asset, location))
                    eastCandidates.append((lon, asset, location))
                    westCandidates.append((lon, asset, location))
                    upCandidates.append((alt, asset, location))
                    downCandidates.append((alt, asset, location))

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

        // Validate high-altitude photos against terrain elevation
        // This filters out airplane photos while keeping legitimate mountain/building photos
        var invalidLocations: Set<String> = []  // Key: "lat,lon" for matching
        let highAltitudePhotos = upCandidates.filter { $0.value > terrainValidationAltitudeThreshold }
        if !highAltitudePhotos.isEmpty {
            debugLog("⛰️ Validating \(highAltitudePhotos.count) high-altitude photos (>\(Int(terrainValidationAltitudeThreshold))m)...")

            // Batch validate in groups of 100 (API limit)
            var invalidAssetIds: Set<String> = []
            let batchSize = 100

            for batchStart in stride(from: 0, to: highAltitudePhotos.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, highAltitudePhotos.count)
                let batch = Array(highAltitudePhotos[batchStart..<batchEnd])

                let coordinates = batch.map { (lat: $0.location.coordinate.latitude, lon: $0.location.coordinate.longitude) }
                let terrainElevations = await fetchTerrainElevations(for: coordinates)

                for (index, photo) in batch.enumerated() {
                    guard let terrainElevation = terrainElevations[index] else {
                        // API failed for this coordinate - allow the photo (fail open)
                        continue
                    }

                    let altitudeAboveTerrain = photo.value - terrainElevation
                    if altitudeAboveTerrain > maxAltitudeAboveTerrainMeters {
                        // Photo is too high above terrain - likely airplane
                        invalidAssetIds.insert(photo.asset.localIdentifier)
                        // Track location for filtering daily statistics
                        let locKey = String(format: "%.4f,%.4f", photo.location.coordinate.latitude, photo.location.coordinate.longitude)
                        invalidLocations.insert(locKey)
                        debugLog("✈️ Filtered airplane photo: \(Int(photo.value))m altitude, terrain: \(Int(terrainElevation))m, above: \(Int(altitudeAboveTerrain))m")
                    }
                }
            }

            if !invalidAssetIds.isEmpty {
                debugLog("⛰️ Filtered \(invalidAssetIds.count) photos likely taken from aircraft")

                // Remove invalid photos from all candidate lists
                func filterCandidates(_ candidates: inout [(value: Double, asset: PHAsset, location: CLLocation)]) {
                    candidates.removeAll { invalidAssetIds.contains($0.asset.localIdentifier) }
                }

                filterCandidates(&northCandidates)
                filterCandidates(&southCandidates)
                filterCandidates(&eastCandidates)
                filterCandidates(&westCandidates)
                filterCandidates(&upCandidates)
                filterCandidates(&downCandidates)
                filterCandidates(&fromHomeCandidates)
            }
        }

        // Filter out airplane locations from daily statistics before recording
        if !invalidLocations.isEmpty {
            allLocationsWithDates.removeAll { loc in
                let locKey = String(format: "%.4f,%.4f", loc.location.coordinate.latitude, loc.location.coordinate.longitude)
                return invalidLocations.contains(locKey)
            }
        }

        // Record ALL valid geotagged photos to daily statistics for accurate graphs
        debugLog("📊 Recording \(allLocationsWithDates.count) locations for daily statistics...")
        await MainActor.run {
            for (location, date) in allLocationsWithDates {
                DailyStatisticManager.shared.recordLocation(location, date: date, homeCoordinate: homeCoordinate, batchMode: true)
            }
            // Flush any remaining batched changes
            DailyStatisticManager.shared.flushBatchChanges()
        }
        debugLog("📊 Daily statistics recording complete")

        // Get current month and year boundaries
        let (startOfMonth, startOfYear) = Date.timeFrameBoundaries()

        // Sort candidates by extremeness
        northCandidates.sort { $0.value > $1.value }  // Highest latitude first
        southCandidates.sort { $0.value < $1.value }  // Lowest latitude first
        eastCandidates.sort { $0.value > $1.value }  // Highest longitude first
        westCandidates.sort { $0.value < $1.value }  // Lowest longitude first
        upCandidates.sort { $0.value > $1.value }  // Highest altitude first
        downCandidates.sort { $0.value < $1.value }  // Lowest altitude first
        fromHomeCandidates.sort { $0.value > $1.value }  // Furthest distance first

        // Convert and filter candidates by timeframe
        func buildCandidatesForTimeframe(
            _ candidates: [(value: Double, asset: PHAsset, location: CLLocation)],
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
        let candidateSets: [(name: String, candidates: [(value: Double, asset: PHAsset, location: CLLocation)], transform: ((Double) -> Double)?)] = [
            ("Furthest North", northCandidates, nil),
            ("Furthest South", southCandidates, nil),
            ("Furthest East", eastCandidates, nil),
            ("Furthest West", westCandidates, nil),
            ("Furthest Up", upCandidates, nil),
            ("Furthest Down", downCandidates, nil),
            ("Furthest from Home", fromHomeCandidates, nil)  // Store in meters (consistent with altitude)
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
            // Start confirmation flow with monthly records first
            currentTimeFrame = .month
            currentRecordTypeIndex = 0
            isConfirming = true
            updateCurrentRecord()
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

            // Note: Daily statistics are recorded during scan, not during import

            // Get photo data from asset
            let photoData = await getPhotoData(from: record.photoAsset)

            // Use the timeframes that were determined during scanning
            let timeFrames = record.beatsTimeFrames
            debugLog("📅 Importing \(record.recordType) for timeframes: \(timeFrames.map { $0.rawValue }.joined(separator: ", "))")

            // Create records for each applicable timeframe
            for timeFrame in timeFrames {
                let detail = RecordDetail(
                    value: record.value,
                    timestamp: record.timestamp,
                    coordinate: record.coordinate,
                    altitude: record.altitude,
                    locationName: record.locationName,
                    recordType: record.recordType,
                    timeFrame: timeFrame,
                    photoData: photoData
                )

                // Add to record manager and history
                await MainActor.run {
                    updateRecordManager(recordType: record.recordType, detail: detail, timeFrame: timeFrame)
                    RecordHistoryManager.shared.addRecord(recordType: record.recordType, detail: detail)
                }
            }
            successCount += 1
        }

        // Create historical yearly and monthly records from all scanned data
        debugLog("📊 Creating historical yearly and monthly records...")
        let historicalCount = await createHistoricalRecords()
        debugLog("📊 Created \(historicalCount) historical records")

        // Remove any duplicate records that may have been created
        let duplicatesRemoved = await MainActor.run {
            RecordHistoryManager.shared.removeDuplicates()
        }

        await MainActor.run {
            importProgress = (selectedRecords.count, selectedRecords.count)
            isImporting = false

            // Clear the photo import cache to free memory
            clearPhotoImportCache()

            // Log summary
            debugLog("✅ Import completed successfully. \(successCount) user-confirmed + \(historicalCount) historical records imported.")
            if duplicatesRemoved > 0 {
                debugLog("🧹 Post-import cleanup: removed \(duplicatesRemoved) duplicate records")
            }

            // Unblock alerts after a delay
            Task {
                try? await Task.sleep(nanoseconds: postImportNotificationSuppressionNanoseconds)
                RecordManager.shared.blockAlertsDuringImport(block: false)
            }

            // Also use the time-based suppression system as backup
            RecordManager.shared.suppressNotificationsAfterImport(durationSeconds: postImportNotificationSuppressionSeconds)
            completion(successCount)
        }
    }

    /// Create historical records for each year and month from scanned data
    /// This populates RecordHistoryEntry with extremes for each time period
    /// Geocoding happens in background after records are created
    private func createHistoricalRecords() async -> Int {
        var recordsCreated = 0
        let calendar = Calendar.current

        // Get all candidates from the allTime bucket (contains all photos)
        guard let allTimeCandidates = candidatesByTimeFrame[.allTime] else {
            return 0
        }

        // Create historical records immediately (without waiting for geocoding)
        for (recordType, candidates) in allTimeCandidates {
            guard !candidates.isEmpty else { continue }

            var byYear: [Int: [DiscoveredRecord]] = [:]
            var byYearMonth: [String: [DiscoveredRecord]] = [:]

            for candidate in candidates {
                let year = calendar.component(.year, from: candidate.timestamp)
                let month = calendar.component(.month, from: candidate.timestamp)
                let yearMonthKey = "\(year)-\(String(format: "%02d", month))"

                byYear[year, default: []].append(candidate)
                byYearMonth[yearMonthKey, default: []].append(candidate)
            }

            let findExtreme: ([DiscoveredRecord]) -> DiscoveredRecord? = { records in
                guard let type = RecordType.from(string: recordType) else {
                    return records.first
                }
                return records.max { candidate1, candidate2 in
                    type.shouldReplace(newValue: candidate2.value, oldValue: candidate1.value)
                }
            }

            // Create yearly records
            for (_, yearCandidates) in byYear {
                guard let extreme = findExtreme(yearCandidates) else { continue }

                let detail = RecordDetail(
                    value: extreme.value,
                    timestamp: extreme.timestamp,
                    coordinate: extreme.coordinate,
                    altitude: extreme.altitude,
                    locationName: nil,  // Will be populated by background geocoding
                    recordType: recordType,
                    timeFrame: .year,
                    photoData: nil
                )

                await MainActor.run {
                    RecordHistoryManager.shared.addRecord(recordType: recordType, detail: detail)
                }
                recordsCreated += 1
            }

            // Create monthly records
            for (_, monthCandidates) in byYearMonth {
                guard let extreme = findExtreme(monthCandidates) else { continue }

                let detail = RecordDetail(
                    value: extreme.value,
                    timestamp: extreme.timestamp,
                    coordinate: extreme.coordinate,
                    altitude: extreme.altitude,
                    locationName: nil,  // Will be populated by background geocoding
                    recordType: recordType,
                    timeFrame: .month,
                    photoData: nil
                )

                await MainActor.run {
                    RecordHistoryManager.shared.addRecord(recordType: recordType, detail: detail)
                }
                recordsCreated += 1
            }
        }

        // Spawn background geocoding task
        Task.detached(priority: .background) {
            await BackgroundGeocoder.shared.geocodeMissingLocations()
        }

        return recordsCreated
    }

    private func updateRecordManager(recordType: String, detail: RecordDetail, timeFrame: TimeFrame) {
        let recordManager = RecordManager.shared
        let existing = recordManager.getRecord(type: recordType, timeFrame: timeFrame)

        // Determine if this record should replace the existing one
        let shouldUpdate: Bool
        if let existing = existing,
           let type = RecordType.from(string: recordType) {
            shouldUpdate = type.shouldReplace(newValue: detail.value, oldValue: existing.value)
            debugLog("🔄 \(recordType) (\(timeFrame.rawValue)): new=\(detail.value) vs existing=\(existing.value), updating=\(shouldUpdate)")
        } else {
            shouldUpdate = true  // No existing record, so set it
            debugLog("🆕 \(recordType) (\(timeFrame.rawValue)): No existing record, setting new one with value=\(detail.value)")
        }

        if shouldUpdate {
            recordManager.setRecord(type: recordType, timeFrame: timeFrame, record: detail)
            debugLog("✅ Updated \(recordType) (\(timeFrame.rawValue)) to \(detail.value)")
        }
    }

    private func getPhotoData(from asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = true

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                // Compress photo data to ensure it's not too large for Core Data
                guard let imageData = data,
                      let uiImage = UIImage(data: imageData),
                      let compressedData = uiImage.jpegData(compressionQuality: 0.7) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: compressedData)
            }
        }
    }
}
