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
