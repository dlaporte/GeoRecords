//
//  RecordDelta.swift
//  GeoRecords
//
//  How far one record value improves on another, in meters, and how to say it.
//  Used by the progression row, the card captions and the home framing line.
//

import Foundation
import CoreLocation

/// Meters per degree of latitude (and of longitude at the equator)
let metersPerDegree = 111_195.0

/// Signed east/west distance in meters between two points measured along `from`'s
/// latitude; positive when `to` is east of `from`. Direction comes from a plain
/// longitude comparison (not the shortest way round), so Japan reads as east of
/// the United States, matching the Stats charts.
func eastWestDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    let alongLatitude = CLLocationCoordinate2D(latitude: from.latitude, longitude: to.longitude)
    let meters = distanceBetween(from: from, to: alongLatitude)
    return to.longitude >= from.longitude ? meters : -meters
}

enum RecordDelta {
    /// How far `newer` improves on `older` for this record type, in meters.
    /// Positive means `newer` is the more extreme value. Nil for region types.
    static func meters(type: RecordType, from older: Double, to newer: Double, atLatitude latitude: Double) -> Double? {
        guard type.isGeographicExtreme else { return nil }
        let raw = newer - older
        let signed = type.isAscending ? raw : -raw
        switch type {
        case .north, .south:
            return signed * metersPerDegree
        case .east, .west:
            return signed * metersPerDegree * cos(latitude * .pi / 180)
        default:
            return signed  // altitude and distance from home are already meters
        }
    }

    /// "212 mi", "2.0 mi", "1,000 ft", "12 km": elevation units for Up, distance
    /// units otherwise, one decimal under ten
    static func format(meters: Double, type: RecordType, unitSystem: UnitSystem) -> String {
        if type == .up {
            return unitSystem == .imperial
                ? FormatUtils.formatFeet(meters * metersToFeet)
                : FormatUtils.formatMeters(meters)
        }
        let value = unitSystem == .imperial ? meters / metersPerMile : meters / metersPerKm
        let decimals = value < 10 ? 1 : 0
        return unitSystem == .imperial
            ? FormatUtils.formatMiles(value, decimals: decimals)
            : FormatUtils.formatKilometers(value, decimals: decimals)
    }
}
