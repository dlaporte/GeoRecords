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
}

@MainActor
class PhotoLibraryScanner: ObservableObject {
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var totalPhotos = 0
    @Published var scannedPhotos = 0
    @Published var photosWithLocation = 0
    @Published var discoveredRecords: [DiscoveredRecord] = []
    @Published var errorMessage: String?

    // Current record being confirmed
    @Published var currentConfirmationIndex = 0
    @Published var isConfirming = false

    // Track all candidates for each record type (sorted by extremeness)
    private var allCandidates: [String: [DiscoveredRecord]] = [:]
    private var currentCandidateIndex: [String: Int] = [:]

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
        currentConfirmationIndex = 0
        isConfirming = false

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

        // Sort candidates by extremeness
        northCandidates.sort { $0.value > $1.value } // Highest latitude first
        southCandidates.sort { $0.value < $1.value } // Lowest latitude first
        eastCandidates.sort { $0.value > $1.value } // Highest longitude first
        westCandidates.sort { $0.value < $1.value } // Lowest longitude first
        upCandidates.sort { $0.value > $1.value } // Highest altitude first
        downCandidates.sort { $0.value < $1.value } // Lowest altitude first
        fromHomeCandidates.sort { $0.value > $1.value } // Furthest distance first

        // Convert all candidates to DiscoveredRecords and store them
        func convertCandidates(_ candidates: [(value: Double, asset: PHAsset, location: CLLocation)],
                              recordType: String,
                              valueTransform: ((Double) -> Double)? = nil) -> [DiscoveredRecord] {
            return candidates.map { candidate in
                let finalValue = valueTransform?(candidate.value) ?? candidate.value
                return DiscoveredRecord(
                    recordType: recordType,
                    value: finalValue,
                    coordinate: candidate.location.coordinate,
                    altitude: candidate.location.altitude,
                    timestamp: candidate.asset.creationDate ?? Date(),
                    photoAsset: candidate.asset,
                    selected: true
                )
            }
        }

        allCandidates = [
            "Furthest North": convertCandidates(northCandidates, recordType: "Furthest North"),
            "Furthest South": convertCandidates(southCandidates, recordType: "Furthest South"),
            "Furthest East": convertCandidates(eastCandidates, recordType: "Furthest East"),
            "Furthest West": convertCandidates(westCandidates, recordType: "Furthest West"),
            "Furthest Up": convertCandidates(upCandidates, recordType: "Furthest Up"),
            "Furthest Down": convertCandidates(downCandidates, recordType: "Furthest Down"),
            "Furthest from Home": convertCandidates(fromHomeCandidates, recordType: "Furthest from Home") { $0 * 3.28084 }
        ]

        // Initialize indices
        currentCandidateIndex = [:]
        for type in allCandidates.keys {
            currentCandidateIndex[type] = 0
        }

        // Build initial discovered records (first candidate of each type)
        var records: [DiscoveredRecord] = []
        for type in ["Furthest North", "Furthest South", "Furthest East", "Furthest West",
                     "Furthest Up", "Furthest Down", "Furthest from Home"] {
            if let candidates = allCandidates[type], !candidates.isEmpty {
                records.append(candidates[0])
            }
        }

        discoveredRecords = records
        isScanning = false

        // Check if we found any records
        if records.isEmpty {
            if photosWithLocation == 0 {
                errorMessage = "No photos with location data found in your library"
            } else {
                errorMessage = "No records found that would beat your current records"
            }
        } else {
            // Start confirmation flow
            isConfirming = true
        }
    }

    func confirmCurrentRecord() {
        if currentConfirmationIndex < discoveredRecords.count {
            discoveredRecords[currentConfirmationIndex].selected = true
            moveToNextConfirmation()
        }
    }

    func rejectCurrentRecord() {
        if currentConfirmationIndex < discoveredRecords.count {
            let currentRecord = discoveredRecords[currentConfirmationIndex]
            let recordType = currentRecord.recordType

            // Mark current as not selected
            discoveredRecords[currentConfirmationIndex].selected = false

            // Try to get next candidate for this record type
            if let candidates = allCandidates[recordType],
               let currentIndex = currentCandidateIndex[recordType] {
                let nextIndex = currentIndex + 1
                if nextIndex < candidates.count {
                    // Replace with next candidate
                    currentCandidateIndex[recordType] = nextIndex
                    discoveredRecords[currentConfirmationIndex] = candidates[nextIndex]
                    // Stay on same confirmation index to show next candidate
                    return
                }
            }

            // No more candidates for this type, move to next record type
            moveToNextConfirmation()
        }
    }

    private func moveToNextConfirmation() {
        currentConfirmationIndex += 1
        if currentConfirmationIndex >= discoveredRecords.count {
            isConfirming = false
        }
    }

    var currentRecord: DiscoveredRecord? {
        guard isConfirming && currentConfirmationIndex < discoveredRecords.count else {
            return nil
        }
        return discoveredRecords[currentConfirmationIndex]
    }

    func importSelectedRecords(completion: @escaping (Int) -> Void) async {
        let selectedRecords = discoveredRecords.filter { $0.selected }

        // Block ALL alerts during import - this is foolproof
        await MainActor.run {
            RecordManager.shared.blockAlertsDuringImport(block: true)
        }

        for record in selectedRecords {
            // Get photo data from asset
            let photoData = await getPhotoData(from: record.photoAsset)

            // Create RecordDetail with photo
            let detail = RecordDetail(
                value: record.value,
                timestamp: record.timestamp,
                coordinate: record.coordinate,
                altitude: record.altitude,
                locationName: nil, // Could geocode if needed
                recordType: record.recordType,
                photoData: photoData
            )

            // Add to record manager and history
            await MainActor.run {
                // Update in-memory record
                updateRecordManager(recordType: record.recordType, detail: detail)

                // Save to Core Data
                RecordHistoryManager.shared.addRecord(recordType: record.recordType, detail: detail)
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

    private func updateRecordManager(recordType: String, detail: RecordDetail) {
        let recordManager = RecordManager.shared

        switch recordType {
        case "Furthest North":
            if let existing = recordManager.furthestNorth {
                if detail.value > existing.value {
                    recordManager.furthestNorth = detail
                }
            } else {
                recordManager.furthestNorth = detail
            }
        case "Furthest South":
            if let existing = recordManager.furthestSouth {
                if detail.value < existing.value {
                    recordManager.furthestSouth = detail
                }
            } else {
                recordManager.furthestSouth = detail
            }
        case "Furthest East":
            if let existing = recordManager.furthestEast {
                if detail.value > existing.value {
                    recordManager.furthestEast = detail
                }
            } else {
                recordManager.furthestEast = detail
            }
        case "Furthest West":
            if let existing = recordManager.furthestWest {
                if detail.value < existing.value {
                    recordManager.furthestWest = detail
                }
            } else {
                recordManager.furthestWest = detail
            }
        case "Furthest Up":
            if let existing = recordManager.furthestUp {
                if detail.value > existing.value {
                    recordManager.furthestUp = detail
                }
            } else {
                recordManager.furthestUp = detail
            }
        case "Furthest Down":
            if let existing = recordManager.furthestDown {
                if detail.value < existing.value {
                    recordManager.furthestDown = detail
                }
            } else {
                recordManager.furthestDown = detail
            }
        case "Furthest from Home":
            if let existing = recordManager.furthestFromHome {
                if detail.value > existing.value {
                    recordManager.furthestFromHome = detail
                }
            } else {
                recordManager.furthestFromHome = detail
            }
        default:
            break
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
