//
//  HomeChangePrompt.swift
//  GeoRecords
//
//  Whether changing home should offer to recalculate "Furthest from Home"
//  records, and how to say it. Only the Settings home picker asks: the setup
//  wizard writes home on every map tap, backup restore brings its own records,
//  and iCloud sync already received recalculated rows from the other device.
//

import Foundation
import CoreLocation

enum HomeChangePrompt {
    static let minimumMoveMeters = 100.0

    static func shouldOffer(oldHome: CLLocationCoordinate2D?, newHome: CLLocationCoordinate2D, fromHomeRowCount: Int) -> Bool {
        guard let oldHome, fromHomeRowCount > 0 else { return false }
        return distanceBetween(from: oldHome, to: newHome) > minimumMoveMeters
    }

    static func message(movedMeters: Double, unitSystem: UnitSystem) -> String {
        let moved = RecordDelta.format(meters: movedMeters, type: .fromHome, unitSystem: unitSystem)
        return "Home moved \(moved). Existing records keep their distance from the old home unless you recalculate, which rewrites every Furthest from Home record from its saved coordinates."
    }
}
