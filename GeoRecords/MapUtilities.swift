//
//  MapUtilities.swift
//  GeoRecords
//
//  Utility functions for map region calculations
//

import MapKit
import CoreLocation

// MARK: - Map Region Calculations

/// Calculates a map region that encompasses all given polygons with padding
/// - Parameters:
///   - polygons: Array of polygon rings (each ring is an array of coordinates)
///   - padding: Multiplier for span (default 1.5 adds 50% padding)
///   - minSpan: Minimum span in degrees (default 0.5, use 5.0 for continents)
///   - defaultRegion: Fallback region if polygons are empty
/// - Returns: MKCoordinateRegion that fits all polygons
func calculateMapRegion(
    for polygons: [[[CLLocationCoordinate2D]]],
    padding: Double = 1.5,
    minSpan: Double = 0.5,
    defaultRegion: MKCoordinateRegion
) -> MKCoordinateRegion {
    guard !polygons.isEmpty else {
        return defaultRegion
    }

    var minLat = Double.infinity
    var maxLat = -Double.infinity
    var minLon = Double.infinity
    var maxLon = -Double.infinity

    for polygon in polygons {
        for ring in polygon {
            for coord in ring {
                minLat = min(minLat, coord.latitude)
                maxLat = max(maxLat, coord.latitude)
                minLon = min(minLon, coord.longitude)
                maxLon = max(maxLon, coord.longitude)
            }
        }
    }

    let center = CLLocationCoordinate2D(
        latitude: (minLat + maxLat) / 2,
        longitude: (minLon + maxLon) / 2
    )

    let spanLat = max((maxLat - minLat) * padding, minSpan)
    let spanLon = max((maxLon - minLon) * padding, minSpan)

    // Validate spans to prevent invalid regions
    let validSpanLat = min(max(spanLat, minSpan), 180.0)
    let validSpanLon = min(max(spanLon, minSpan), 360.0)

    return MKCoordinateRegion(
        center: center,
        span: MKCoordinateSpan(latitudeDelta: validSpanLat, longitudeDelta: validSpanLon)
    )
}

// MARK: - Region Overlay Cache

/// Process-wide cache of display-ready map overlays and camera regions, keyed by
/// region code or continent. The bundled 10m boundary data holds ~550k vertices;
/// converting them into MKPolygons is far too expensive to repeat on every SwiftUI
/// update. MKPolygon/MKPolyline are immutable model objects, so sharing them across
/// map views is safe — each map view builds its own renderers.
@MainActor
final class RegionOverlayCache {
    static let shared = RegionOverlayCache()

    private var polygonsByCode: [String: [MKPolygon]] = [:]
    private var polygonsByContinent: [Continent: [MKPolygon]] = [:]
    private var cameraByCode: [String: MKCoordinateRegion] = [:]
    private var cameraByContinent: [Continent: MKCoordinateRegion] = [:]
    private var usOutline: [MKPolyline]?

    private init() {}

    /// Display polygons for a region code (title = region name, subtitle = code,
    /// matching what the map renderers key their styling on)
    func polygons(for code: String, title: String?) -> [MKPolygon] {
        if let cached = polygonsByCode[code] { return cached }
        var result: [MKPolygon] = []
        for polygonGroup in RegionLookupService.shared.polygons(for: code) {
            for coordinates in polygonGroup where coordinates.count > 2 {
                var coords = coordinates
                let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                polygon.title = title
                polygon.subtitle = code
                result.append(polygon)
            }
        }
        polygonsByCode[code] = result
        return result
    }

    /// Display polygons for a continent (title = continent name, matching the renderer)
    func polygons(for continent: Continent) -> [MKPolygon] {
        if let cached = polygonsByContinent[continent] { return cached }
        var result: [MKPolygon] = []
        for polygonGroup in RegionLookupService.shared.continentPolygons(for: continent) {
            for coordinates in polygonGroup where coordinates.count > 2 {
                var coords = coordinates
                let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                polygon.title = continent.rawValue
                result.append(polygon)
            }
        }
        polygonsByContinent[continent] = result
        return result
    }

    /// Camera region framing a region code's polygons (computed once per code)
    func cameraRegion(for code: String, defaultRegion: MKCoordinateRegion) -> MKCoordinateRegion {
        if let cached = cameraByCode[code] { return cached }
        let polygonArrays = RegionLookupService.shared.polygons(for: code)
        guard !polygonArrays.isEmpty else { return defaultRegion }
        let region = calculateMapRegion(for: polygonArrays, defaultRegion: defaultRegion)
        cameraByCode[code] = region
        return region
    }

    /// Camera region framing a continent (wider padding and minimum span)
    func cameraRegion(for continent: Continent, defaultRegion: MKCoordinateRegion) -> MKCoordinateRegion {
        if let cached = cameraByContinent[continent] { return cached }
        let polygonArrays = RegionLookupService.shared.continentPolygons(for: continent)
        guard !polygonArrays.isEmpty else { return defaultRegion }
        let region = calculateMapRegion(
            for: polygonArrays,
            padding: 1.3,  // 30% padding for continents
            minSpan: 5.0,  // Larger minimum span for continents
            defaultRegion: defaultRegion
        )
        cameraByContinent[continent] = region
        return region
    }

    /// US outline polylines for the states map base layer
    func usOutlinePolylines() -> [MKPolyline] {
        if let cached = usOutline { return cached }
        var result: [MKPolyline] = []
        for lineString in RegionLookupService.shared.getUSOutlinePolylines() where lineString.count > 1 {
            var coords = lineString
            let polyline = MKPolyline(coordinates: &coords, count: coords.count)
            polyline.title = "outline"
            result.append(polyline)
        }
        usOutline = result
        return result
    }
}
