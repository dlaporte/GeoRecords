//
//  NotYetRegions.swift
//  GeoRecords
//
//  The unvisited side of the Regions tab: the region kinds' polygons and cameras,
//  the nearest-border distance from home, and the callout shown for a tapped
//  unvisited region ("Idaho · not yet · ~250 mi away").
//

import Foundation
import CoreLocation
import MapKit

struct NotYetRegion: Identifiable, Equatable {
    let code: String
    let name: String
    var id: String { code }
}

/// Which kind of region a Regions tab shows, for polygon and camera lookups
enum NotYetKind {
    case state, country, continent

    /// Polygons for a region of this kind (safe off the main actor)
    func polygons(for code: String) -> [[[CLLocationCoordinate2D]]] {
        switch self {
        case .continent:
            guard let continent = Continent(rawValue: code) else { return [] }
            return RegionLookupService.shared.continentPolygons(for: continent)
        case .state, .country:
            return RegionLookupService.shared.polygons(for: code)
        }
    }

    /// Camera framing a region of this kind
    @MainActor
    func camera(for code: String, defaultRegion: MKCoordinateRegion) -> MKCoordinateRegion {
        switch self {
        case .continent:
            guard let continent = Continent(rawValue: code) else { return defaultRegion }
            return RegionOverlayCache.shared.cameraRegion(for: continent, defaultRegion: defaultRegion)
        case .state, .country:
            return RegionOverlayCache.shared.cameraRegion(for: code, defaultRegion: defaultRegion)
        }
    }
}

enum RegionDistance {
    /// Distance from home to the closest polygon vertex, in meters (nil with no polygons)
    static func nearestMeters(from home: CLLocationCoordinate2D, polygons: [[[CLLocationCoordinate2D]]]) -> Double? {
        var best: Double?
        for polygon in polygons {
            for ring in polygon {
                for vertex in ring {
                    let meters = distanceBetween(from: home, to: vertex)
                    if best == nil || meters < best! { best = meters }
                }
            }
        }
        return best
    }

    /// "~90 mi away": rounded to one figure below 100 and two above, since the
    /// measurement is to the nearest border point anyway
    static func approximateText(meters: Double, unitSystem: UnitSystem) -> String {
        let value = unitSystem == .imperial ? meters / metersPerMile : meters / metersPerKm
        let rounded: Double
        if value < 10 {
            rounded = value.rounded()
        } else if value < 100 {
            rounded = (value / 10).rounded() * 10
        } else {
            let magnitude = pow(10, floor(log10(value)) - 1)
            rounded = (value / magnitude).rounded() * magnitude
        }
        return "~\(FormatUtils.formatWholeNumber(rounded)) \(unitSystem.distanceUnit) away"
    }
}

/// What the map shows after a tap on a region that is not visited yet
struct UnvisitedCallout: Equatable {
    let name: String
    let code: String
    let distanceText: String?
}
