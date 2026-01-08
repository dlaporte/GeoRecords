//
//  WidgetMapGenerator.swift
//  GeoRecords
//
//  Generates map snapshots for the widget to display visited regions
//

import Foundation
import MapKit
import UIKit

/// Generates and caches map images for widget display
@MainActor
class WidgetMapGenerator {
    static let shared = WidgetMapGenerator()

    private let appGroupIdentifier = "group.com.georecords.shared"

    /// Map types that can be generated
    enum MapType: String, CaseIterable {
        case states = "widget_map_states.png"
        case countries = "widget_map_countries.png"
        case continents = "widget_map_continents.png"

        /// Default region used when no custom region is saved
        var defaultRegion: MKCoordinateRegion {
            switch self {
            case .states:
                // US centered to show continental US, Alaska, Hawaii, and Puerto Rico
                // Note: Guam (144°E) is too far west to include in a US-centered view
                // Center shifted west to better include Hawaii and Alaska
                return MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 45, longitude: -120),
                    span: MKCoordinateSpan(latitudeDelta: 75, longitudeDelta: 100)
                )
            case .countries, .continents:
                // World view centered on prime meridian (0° longitude)
                // Note: MKMapSnapshotter cannot handle 360° spans, use ~300° max
                // Users can customize via the Set Widget View feature
                return MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                    span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 280)
                )
            }
        }

        var fillColor: UIColor {
            switch self {
            case .states: return UIColor.systemBlue.withAlphaComponent(0.4)
            case .countries: return UIColor.systemGreen.withAlphaComponent(0.4)
            case .continents: return UIColor.systemOrange.withAlphaComponent(0.4)
            }
        }

        var strokeColor: UIColor {
            switch self {
            case .states: return UIColor.systemBlue
            case .countries: return UIColor.systemGreen
            case .continents: return UIColor.systemOrange
            }
        }

        /// Image size optimized for large widget content area (after header)
        var imageSize: CGSize {
            // Use same aspect ratio for all map types (matches widget content area)
            return widgetMapSize
        }
    }

    private init() {}

    /// Clear all cached map images
    func clearAllCachedMaps() {
        for mapType in MapType.allCases {
            clearCachedMap(for: mapType)
        }
        debugLog("📍 WidgetMapGenerator: Cleared all cached maps")
    }

    /// Generate and cache all map types
    func generateAllMaps() async {
        // Clear old cached images first to ensure fresh generation
        clearAllCachedMaps()

        for mapType in MapType.allCases {
            await generateMap(for: mapType)
        }
        debugLog("📍 WidgetMapGenerator: Generated all map snapshots")
    }

    /// Generate and cache a specific map type
    func generateMap(for mapType: MapType) async {
        let regionCodes: [String]

        switch mapType {
        case .states:
            regionCodes = RegionTrackingManager.shared.visitedStates.compactMap { $0.regionCode }
        case .countries:
            regionCodes = RegionTrackingManager.shared.visitedCountries.compactMap { $0.regionCode }
        case .continents:
            // For continents, we handle separately below
            regionCodes = []
        }

        // Get polygons for all visited regions
        var allPolygons: [MKPolygon] = []

        if mapType == .continents {
            // Get continent polygons from visited continents
            let visitedContinents = RegionTrackingManager.shared.visitedContinents
            guard !visitedContinents.isEmpty else {
                clearCachedMap(for: mapType)
                return
            }

            for continentRecord in visitedContinents {
                guard let continentName = continentRecord.locationName,
                      let continent = Continent(rawValue: continentName) else { continue }
                let polygonArrays = RegionLookupService.shared.continentPolygons(for: continent)
                for polygonGroup in polygonArrays {
                    for coordinates in polygonGroup {
                        guard coordinates.count > 2 else { continue }
                        var coords = coordinates
                        let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                        allPolygons.append(polygon)
                    }
                }
            }
        } else {
            guard !regionCodes.isEmpty else {
                // No regions to display, clear any existing cache
                clearCachedMap(for: mapType)
                return
            }

            for code in regionCodes {
                let polygonArrays = RegionLookupService.shared.polygons(for: code)
                for polygonGroup in polygonArrays {
                    for coordinates in polygonGroup {
                        guard coordinates.count > 2 else { continue }
                        var coords = coordinates
                        let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                        allPolygons.append(polygon)
                    }
                }
            }
        }

        guard !allPolygons.isEmpty else {
            debugLog("⚠️ WidgetMapGenerator: No polygons found for \(mapType)")
            return
        }

        // Get region (saved custom region or default)
        let region: MKCoordinateRegion
        switch mapType {
        case .states:
            region = SettingsManager.shared.widgetMapStatesRegion ?? mapType.defaultRegion
        case .countries:
            region = SettingsManager.shared.widgetMapCountriesRegion ?? mapType.defaultRegion
        case .continents:
            region = SettingsManager.shared.widgetMapContinentsRegion ?? mapType.defaultRegion
        }

        // Generate the map snapshot
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = mapType.imageSize
        options.scale = UIScreen.main.scale

        let snapshotter = MKMapSnapshotter(options: options)

        do {
            let snapshot = try await snapshotter.start()

            // Draw the snapshot with polygons overlaid
            let image = drawPolygons(allPolygons, on: snapshot, mapType: mapType)

            // Save to App Group
            saveImage(image, for: mapType)
            debugLog("📍 WidgetMapGenerator: Generated \(mapType) map with \(allPolygons.count) polygons, size: \(image.size.width)x\(image.size.height)")
        } catch {
            debugLog("⚠️ WidgetMapGenerator: Failed to generate snapshot: \(error)")
        }
    }

    /// Draw polygons on the map snapshot
    private func drawPolygons(_ polygons: [MKPolygon], on snapshot: MKMapSnapshotter.Snapshot, mapType: MapType) -> UIImage {
        let image = snapshot.image

        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        image.draw(at: .zero)

        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return image
        }

        context.setFillColor(mapType.fillColor.cgColor)
        context.setStrokeColor(mapType.strokeColor.cgColor)
        context.setLineWidth(1.0)

        for polygon in polygons {
            let path = UIBezierPath()
            let points = polygon.points()
            let pointCount = polygon.pointCount

            guard pointCount > 0 else { continue }

            // Convert the first point
            let firstCoord = points[0].coordinate
            let firstPoint = snapshot.point(for: firstCoord)
            path.move(to: firstPoint)

            // Add remaining points
            for i in 1..<pointCount {
                let coord = points[i].coordinate
                let point = snapshot.point(for: coord)
                path.addLine(to: point)
            }

            path.close()
            path.fill()
            path.stroke()
        }

        let resultImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()

        return resultImage
    }

    /// Save image to App Group shared storage
    private func saveImage(_ image: UIImage, for mapType: MapType) {
        guard let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            debugLog("⚠️ WidgetMapGenerator: Could not access App Group container")
            return
        }

        let fileURL = appGroupURL.appendingPathComponent(mapType.rawValue)

        guard let data = image.pngData() else {
            debugLog("⚠️ WidgetMapGenerator: Could not create PNG data")
            return
        }

        do {
            try data.write(to: fileURL)
            debugLog("📍 WidgetMapGenerator: Saved \(mapType) to \(fileURL.lastPathComponent)")
        } catch {
            debugLog("⚠️ WidgetMapGenerator: Failed to save image: \(error)")
        }
    }

    /// Clear cached map image
    private func clearCachedMap(for mapType: MapType) {
        guard let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return
        }

        let fileURL = appGroupURL.appendingPathComponent(mapType.rawValue)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
