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
    var longitudes: [Double] = []

    for polygon in polygons {
        for ring in polygon {
            for coord in ring {
                minLat = min(minLat, coord.latitude)
                maxLat = max(maxLat, coord.latitude)
                longitudes.append(coord.longitude)
            }
        }
    }

    guard let (minLon, maxLon) = longitudeExtent(of: longitudes) else {
        return defaultRegion
    }

    var centerLon = (minLon + maxLon) / 2
    if centerLon > 180 { centerLon -= 360 }
    let center = CLLocationCoordinate2D(
        latitude: (minLat + maxLat) / 2,
        longitude: centerLon
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

/// The longitude range covering a set of points, measured around the globe rather
/// than on the -180…180 number line. The United States (Aleutians), Russia, Fiji,
/// New Zealand and the North America mainland all cross the antimeridian; a plain
/// min/max on those spans the whole world and centers the camera on the prime
/// meridian. The covered range is the complement of the largest empty gap between
/// the sorted longitudes, so a range that wraps is returned with `max` above 180
/// (e.g. 170…308 for a region from the Aleutians to Greenland).
func longitudeExtent(of longitudes: [Double]) -> (min: Double, max: Double)? {
    let sorted = longitudes.sorted()
    guard let first = sorted.first, let last = sorted.last else { return nil }

    var largestGap = first + 360 - last   // the gap across the antimeridian
    var gapStartIndex: Int? = nil         // nil = the largest gap is the wrap-around one
    for i in 0..<(sorted.count - 1) {
        let gap = sorted[i + 1] - sorted[i]
        if gap > largestGap {
            largestGap = gap
            gapStartIndex = i
        }
    }

    guard let i = gapStartIndex else {
        return (first, last)  // no wrap: the plain bounding box is right
    }
    // The points live everywhere except (sorted[i], sorted[i+1]); cover them eastward
    // from the gap's far side around to its near side
    return (sorted[i + 1], sorted[i] + 360)
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
    private var multiPolygonByContinent: [Continent: MKMultiPolygon] = [:]
    private var cameraByCode: [String: MKCoordinateRegion] = [:]
    private var cameraByContinent: [Continent: MKCoordinateRegion] = [:]
    private var usOutline: [MKPolyline]?

    private init() {}

    /// One MKPolygon from a polygon's rings: the exterior only. Interior polygons
    /// are deliberately not passed on: with them, MKMapView silently stops drawing
    /// whole tiles of the overlay (bisected in the simulator, Nov 2026; the same
    /// polygons draw fine through the renderer directly). The holes are enclaves,
    /// which the overlay of their own country or continent covers anyway, and the
    /// one sizeable hole in a continent outline is a gap in the data (eastern
    /// Bosnia), better filled than not.
    private static func makePolygon(rings: [[CLLocationCoordinate2D]]) -> MKPolygon? {
        guard var exterior = rings.first, exterior.count > 2 else { return nil }
        return MKPolygon(coordinates: &exterior, count: exterior.count)
    }

    /// Display polygons for a region code (title = region name, subtitle = code,
    /// matching what the map renderers key their styling on)
    func polygons(for code: String, title: String?) -> [MKPolygon] {
        if let cached = polygonsByCode[code] { return cached }
        var result: [MKPolygon] = []
        for polygonGroup in RegionLookupService.shared.polygons(for: code) {
            guard let polygon = Self.makePolygon(rings: polygonGroup) else { continue }
            polygon.title = title
            polygon.subtitle = code
            result.append(polygon)
        }
        polygonsByCode[code] = result
        return result
    }

    /// Display overlay for a continent (title = continent name, matching the renderer).
    /// A continent outline is every island too, over a thousand polygons for North
    /// America, so it is one MKMultiPolygon: one overlay and one renderer per
    /// continent instead of one per polygon.
    func multiPolygon(for continent: Continent) -> MKMultiPolygon {
        if let cached = multiPolygonByContinent[continent] { return cached }
        let polygons = RegionLookupService.shared.continentPolygons(for: continent).compactMap(Self.makePolygon)
        let multiPolygon = MKMultiPolygon(polygons)
        multiPolygon.title = continent.rawValue
        multiPolygonByContinent[continent] = multiPolygon
        return multiPolygon
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

    /// Camera region framing a continent's mainland (wider padding and minimum span)
    func cameraRegion(for continent: Continent, defaultRegion: MKCoordinateRegion) -> MKCoordinateRegion {
        if let cached = cameraByContinent[continent] { return cached }
        let polygonArrays = RegionLookupService.shared.continentExtentPolygons(for: continent)
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
