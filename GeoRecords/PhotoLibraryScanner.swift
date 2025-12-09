import Foundation
import Photos
import CoreLocation
import UIKit

// Discovered record from photo library
struct DiscoveredRecord: Identifiable {
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
        let batchSize = 100
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

                    guard let location = asset.location else { continue }

                    await MainActor.run {
                        self.photosWithLocation += 1
                    }

                    let lat = location.coordinate.latitude
                    let lon = location.coordinate.longitude
                    let alt = location.altitude

                    // Collect ALL candidates for each direction
                    northCandidates.append((lat, asset, location))
                    southCandidates.append((lat, asset, location))
                    eastCandidates.append((lon, asset, location))
                    westCandidates.append((lon, asset, location))
                    upCandidates.append((alt, asset, location))
                    downCandidates.append((alt, asset, location))

                    // Distance from home
                    if let homeCoord = homeCoordinate {
                        let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
                        let distance = location.distance(from: homeLocation)
                        fromHomeCandidates.append((distance, asset, location))
                    }
                }
            }.value

            // Brief yield to UI
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }

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
            ("Furthest from Home", fromHomeCandidates, { $0 * metersToFeet })
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
               candidateIndex < candidates.count {
                // Found a candidate to show
                discoveredRecords = [candidates[candidateIndex]]
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
               candidateIndex < candidates.count {
                // Show next candidate
                discoveredRecords = [candidates[candidateIndex]]
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

        // Block ALL alerts during import - this is foolproof
        await MainActor.run {
            RecordManager.shared.blockAlertsDuringImport(block: true)
        }

        for record in selectedRecords {
            // Get photo data from asset
            let photoData = await getPhotoData(from: record.photoAsset)

            // Use the timeframes that were determined during scanning
            // (These are the specific timeframes this photo was selected for)
            let timeFrames = record.beatsTimeFrames
            debugLog("📅 Importing \(record.recordType) for timeframes: \(timeFrames.map { $0.rawValue }.joined(separator: ", "))")

            // Create records for each applicable timeframe
            for timeFrame in timeFrames {
                let detail = RecordDetail(
                    value: record.value,
                    timestamp: record.timestamp,
                    coordinate: record.coordinate,
                    altitude: record.altitude,
                    locationName: record.locationName,  // Use geocoded name from confirmation
                    recordType: record.recordType,
                    timeFrame: timeFrame,
                    photoData: photoData
                )

                // Add to record manager and history
                await MainActor.run {
                    // Update in-memory record
                    updateRecordManager(recordType: record.recordType, detail: detail, timeFrame: timeFrame)

                    // Save to Core Data
                    RecordHistoryManager.shared.addRecord(recordType: record.recordType, detail: detail)
                }
            }
        }

        await MainActor.run {
            // Unblock alerts after a delay
            Task {
                try? await Task.sleep(nanoseconds: 180_000_000_000) // 180 seconds = 3 minutes
                RecordManager.shared.blockAlertsDuringImport(block: false)
            }

            // Also use the time-based suppression system as backup
            RecordManager.shared.suppressNotificationsAfterImport(durationSeconds: 180)
            completion(selectedRecords.count)
        }
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
