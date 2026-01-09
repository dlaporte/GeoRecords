//
//  WidgetMapGenerator.swift
//  GeoRecords
//
//  Generates map snapshots for the widget to display visited regions
//

import Foundation
import MapKit
import UIKit
import WidgetKit

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

        // Verify all files exist
        verifyAllMaps()

        // Trigger widget refresh so they pick up the new map images
        WidgetCenter.shared.reloadAllTimelines()
        debugLog("📍 WidgetMapGenerator: Triggered widget timeline refresh")
    }

    /// Generate and cache a specific map type
    func generateMap(for mapType: MapType) async {
        debugLog("📍 WidgetMapGenerator: Starting generation for \(mapType)")

        let regionCodes: [String]

        switch mapType {
        case .states:
            regionCodes = RegionTrackingManager.shared.visitedStates.compactMap { $0.regionCode }
            debugLog("📍 WidgetMapGenerator: Found \(regionCodes.count) visited states")
        case .countries:
            regionCodes = RegionTrackingManager.shared.visitedCountries.compactMap { $0.regionCode }
            debugLog("📍 WidgetMapGenerator: Found \(regionCodes.count) visited countries")
        case .continents:
            // For continents, we handle separately below
            regionCodes = []
            debugLog("📍 WidgetMapGenerator: Processing continents separately")
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
        let hasCustomRegion: Bool
        switch mapType {
        case .states:
            hasCustomRegion = SettingsManager.shared.widgetMapStatesRegion != nil
            region = SettingsManager.shared.widgetMapStatesRegion ?? mapType.defaultRegion
        case .countries:
            hasCustomRegion = SettingsManager.shared.widgetMapCountriesRegion != nil
            region = SettingsManager.shared.widgetMapCountriesRegion ?? mapType.defaultRegion
        case .continents:
            hasCustomRegion = SettingsManager.shared.widgetMapContinentsRegion != nil
            region = SettingsManager.shared.widgetMapContinentsRegion ?? mapType.defaultRegion
        }
        debugLog("📍 WidgetMapGenerator: \(mapType) using \(hasCustomRegion ? "custom" : "default") region - center: (\(region.center.latitude), \(region.center.longitude)), span: (\(region.span.latitudeDelta), \(region.span.longitudeDelta))")

        // Generate the map snapshot
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = mapType.imageSize
        options.scale = UIScreen.main.scale

        let snapshotter = MKMapSnapshotter(options: options)

        do {
            debugLog("📍 WidgetMapGenerator: Starting MKMapSnapshotter for \(mapType)...")
            let snapshot = try await snapshotter.start()
            debugLog("📍 WidgetMapGenerator: Snapshot completed for \(mapType), drawing \(allPolygons.count) polygons...")

            // Draw the snapshot with polygons overlaid
            let image = drawPolygons(allPolygons, on: snapshot, mapType: mapType)
            debugLog("📍 WidgetMapGenerator: Drawing complete for \(mapType), image size: \(image.size.width)x\(image.size.height)")

            // Save to App Group
            saveImage(image, for: mapType)
        } catch {
            debugLog("⚠️ WidgetMapGenerator: Failed to generate snapshot for \(mapType): \(error)")
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

        // Threshold for detecting antimeridian crossing - if X jumps more than 40% of image width, skip segment
        let antimeridianThreshold = image.size.width * 0.4

        for polygon in polygons {
            let path = UIBezierPath()
            let points = polygon.points()
            let pointCount = polygon.pointCount

            guard pointCount > 0 else { continue }

            // Convert the first point
            let firstCoord = points[0].coordinate
            var lastPoint = snapshot.point(for: firstCoord)
            path.move(to: lastPoint)

            // Add remaining points, but skip segments that cross the antimeridian
            for i in 1..<pointCount {
                let coord = points[i].coordinate
                let point = snapshot.point(for: coord)

                // Check if this segment crosses the antimeridian (huge X jump)
                let xDelta = abs(point.x - lastPoint.x)
                if xDelta > antimeridianThreshold {
                    // Start a new subpath instead of drawing a line across the map
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
                lastPoint = point
            }

            // Don't close the path if it would cross the antimeridian
            let firstPoint = snapshot.point(for: firstCoord)
            let closingXDelta = abs(firstPoint.x - lastPoint.x)
            if closingXDelta <= antimeridianThreshold {
                path.close()
            }

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
            debugLog("📍 WidgetMapGenerator: ✅ Successfully saved \(mapType) to \(fileURL.path)")

            // Verify the file was written and can be read back
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            if fileExists {
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = attrs?[.size] as? Int ?? 0
                debugLog("📍 WidgetMapGenerator: ✅ Verified \(mapType) file exists, size: \(fileSize) bytes")
            } else {
                debugLog("⚠️ WidgetMapGenerator: ❌ File verification failed - file does not exist after save!")
            }
        } catch {
            debugLog("⚠️ WidgetMapGenerator: ❌ Failed to save \(mapType) image: \(error)")
        }
    }

    /// Clear cached map image
    private func clearCachedMap(for mapType: MapType) {
        guard let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            debugLog("⚠️ WidgetMapGenerator: Could not get App Group URL for clearing \(mapType)")
            return
        }

        let fileURL = appGroupURL.appendingPathComponent(mapType.rawValue)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
            debugLog("📍 WidgetMapGenerator: Cleared cached \(mapType)")
        }
    }

    /// Verify all map files exist (for debugging)
    func verifyAllMaps() {
        guard let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            debugLog("⚠️ WidgetMapGenerator: Could not get App Group URL")
            return
        }

        debugLog("📍 WidgetMapGenerator: App Group URL = \(appGroupURL.path)")

        for mapType in MapType.allCases {
            let fileURL = appGroupURL.appendingPathComponent(mapType.rawValue)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = attrs?[.size] as? Int ?? 0
                debugLog("📍 WidgetMapGenerator: ✅ \(mapType.rawValue) exists (\(fileSize) bytes)")
            } else {
                debugLog("📍 WidgetMapGenerator: ❌ \(mapType.rawValue) NOT FOUND")
            }
        }
    }
}
