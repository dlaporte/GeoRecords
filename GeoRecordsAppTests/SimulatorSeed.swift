//
//  SimulatorSeed.swift
//  GeoRecordsTests
//
//  Not a test of the app: a development tool that fills the host app's real store
//  with sample records so screens can be eyeballed in the simulator. It runs only
//  when GEORECORDS_SEED=1 is in the test environment (pass it to xcodebuild as
//  TEST_RUNNER_GEORECORDS_SEED=1) and is a no-op otherwise, so CI never seeds.
//

import Testing
import CoreData
import CoreLocation
import UIKit
@testable import GeoRecords

@MainActor
struct SimulatorSeed {

    @Test func seedSampleDataWhenAsked() async throws {
        guard ProcessInfo.processInfo.environment["GEORECORDS_SEED"] == "1" else { return }

        let context = PersistenceController.shared.container.viewContext
        for entityName in ["RecordHistoryEntry", "VisitedRegion"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in (try? context.fetch(request)) ?? [] { context.delete(object) }
        }
        try context.save()

        let home = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
        // A few records carry a photo (an embedded JPEG, as a record saved from the
        // new-record prompt would), so the screens show the photo path, not the
        // map fallback; Furthest South stays photo-less for the map slot
        func place(_ type: RecordType, _ timeFrame: TimeFrame, _ value: Double?, lat: Double, lon: Double,
                   _ name: String, _ date: Date, altitude: Double = 0, photo: Bool = false) {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let stored: Double
            switch type {
            case .north, .south: stored = lat
            case .east, .west: stored = lon
            case .up: stored = altitude
            case .fromHome: stored = distanceBetween(from: coordinate, to: home)
            default: stored = value ?? date.timeIntervalSince1970
            }
            let row = insertRow(context, type: type.rawValue, timeFrame: timeFrame.rawValue, value: stored,
                                lat: lat, lon: lon, timestamp: date, locationName: name)
            row.altitude = altitude
            if photo { row.photoData = SeedPhoto.jpeg(titled: name) }
        }

        // Lifetime records with a previous one each (progression rows)
        place(.north, .allTime, nil, lat: 64.1466, lon: -21.9426, "Reykjavík, Iceland", noon(2023, 8, 10))
        place(.north, .allTime, nil, lat: 69.6492, lon: 18.9553, "Tromsø, Norway", noon(2024, 6, 3), photo: true)
        place(.south, .allTime, nil, lat: 21.1619, lon: -86.8515, "Cancún, Mexico", noon(2022, 5, 1))
        place(.south, .allTime, nil, lat: -34.6037, lon: -58.3816, "Buenos Aires, Argentina", noon(2025, 2, 14))
        place(.east, .allTime, nil, lat: 69.6492, lon: 18.9553, "Tromsø, Norway", noon(2024, 6, 3), photo: true)
        place(.west, .allTime, nil, lat: 21.3069, lon: -157.8583, "Honolulu, HI", noon(2023, 11, 20), photo: true)
        place(.up, .allTime, nil, lat: 45.3736, lon: -121.6960, "Mount Hood, OR", noon(2024, 7, 15), altitude: 3_429)
        place(.up, .allTime, nil, lat: 46.8523, lon: -121.7603, "Mount Rainier, WA", noon(2025, 9, 1), altitude: 4_392)
        place(.fromHome, .allTime, nil, lat: -34.6037, lon: -58.3816, "Buenos Aires, Argentina", noon(2025, 2, 14))

        // This year
        place(.north, .year, nil, lat: 49.2827, lon: -123.1207, "Vancouver, Canada", noon(2026, 10, 12))
        place(.south, .year, nil, lat: 32.7157, lon: -117.1611, "San Diego, CA", noon(2026, 7, 4))
        place(.east, .year, nil, lat: 42.3601, lon: -71.0589, "Boston, MA", noon(2026, 3, 20))
        place(.west, .year, nil, lat: 48.3681, lon: -124.6244, "Neah Bay, WA", noon(2026, 8, 15))
        place(.up, .year, nil, lat: 46.1914, lon: -122.1956, "Mount St. Helens, WA", noon(2026, 6, 10), altitude: 2_549)
        place(.fromHome, .year, nil, lat: 42.3601, lon: -71.0589, "Boston, MA", noon(2026, 3, 20))

        // This month (within reach of the yearly furthest north and up)
        let thisMonth = Calendar.current.date(byAdding: .hour, value: -3, to: Date())!
        place(.north, .month, nil, lat: 48.7519, lon: -122.4787, "Bellingham, WA", thisMonth)
        place(.south, .month, nil, lat: 45.5152, lon: -122.6784, "Portland, OR", thisMonth)
        place(.east, .month, nil, lat: 47.6588, lon: -117.4260, "Spokane, WA", thisMonth)
        place(.west, .month, nil, lat: 47.8021, lon: -123.4000, "Olympic National Park, WA", thisMonth)
        place(.up, .month, nil, lat: 47.4249, lon: -121.4133, "Snoqualmie Pass, WA", thisMonth, altitude: 921)
        place(.fromHome, .month, nil, lat: 47.6588, lon: -117.4260, "Spokane, WA", thisMonth)

        // Regions
        func region(_ type: RecordType, code: String, _ name: String, lat: Double, lon: Double, _ date: Date, photo: Bool = false) {
            let row = insertRow(context, type: type.rawValue, timeFrame: TimeFrame.allTime.rawValue,
                                value: date.timeIntervalSince1970, lat: lat, lon: lon, timestamp: date,
                                source: "photo", locationName: name, regionCode: code)
            if photo { row.photoData = SeedPhoto.jpeg(titled: name) }
        }
        region(.state, code: "US-WA", "Washington", lat: 47.6062, lon: -122.3321, noon(2019, 1, 1), photo: true)
        region(.state, code: "US-OR", "Oregon", lat: 45.5152, lon: -122.6784, noon(2021, 7, 4))
        region(.state, code: "US-NV", "Nevada", lat: 36.1699, lon: -115.1398, noon(2022, 6, 3), photo: true)
        region(.country, code: "US", "United States", lat: 47.6062, lon: -122.3321, noon(2019, 1, 1))
        region(.country, code: "JP", "Japan", lat: 35.6762, lon: 139.6503, noon(2023, 4, 10))
        region(.country, code: "FR", "France", lat: 48.8566, lon: 2.3522, noon(2024, 6, 1))
        region(.continent, code: "North America", "North America", lat: 47.6062, lon: -122.3321, noon(2019, 1, 1))
        region(.continent, code: "Asia", "Asia", lat: 35.6762, lon: 139.6503, noon(2023, 4, 10))
        region(.continent, code: "Europe", "Europe", lat: 48.8566, lon: 2.3522, noon(2024, 6, 1))
        try context.save()

        let settings = SettingsManager.shared
        settings.homeCoordinate = home
        settings.homeLocationName = "Seattle, WA"
        settings.hasCompletedSetup = true
        settings.saveSettings()
    }
}

/// A 4:3 stand-in photo: a sky-to-sea gradient with the place name, 1600 × 1200
enum SeedPhoto {
    @MainActor
    static func jpeg(titled title: String) -> Data? {
        let size = CGSize(width: 1600, height: 1200)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.85, green: 0.75, blue: 0.54, alpha: 1).cgColor,
                          UIColor(red: 0.54, green: 0.48, blue: 0.38, alpha: 1).cgColor,
                          UIColor(red: 0.24, green: 0.29, blue: 0.34, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 72, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9)
            ]
            (title as NSString).draw(at: CGPoint(x: 60, y: size.height - 150), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}
