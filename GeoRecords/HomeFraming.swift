//
//  HomeFraming.swift
//  GeoRecords
//
//  The record card's secondary block: "312 mi north of home" for the latitude and
//  longitude records when home is set, cardinal coordinates otherwise.
//

import Foundation
import CoreLocation

enum HomeFraming {
    static func text(for record: RecordDetail, home: CLLocationCoordinate2D?, unitSystem: UnitSystem) -> (label: String, value: String) {
        let coordinates = (label: "Coordinates", value: FormatUtils.formatCoordinatesWithCardinals(record.coordinate))
        guard let home, let type = RecordType.from(string: record.recordType) else { return coordinates }

        let meters: Double
        let directions: (positive: String, negative: String)
        switch type {
        case .north, .south:
            meters = northSouthDistance(from: home, to: record.coordinate)
            directions = ("north", "south")
        case .east, .west:
            meters = eastWestDistance(from: home, to: record.coordinate)
            directions = ("east", "west")
        default:
            return coordinates
        }

        let amount = RecordDelta.format(meters: abs(meters), type: .fromHome, unitSystem: unitSystem)
        let direction = meters >= 0 ? directions.positive : directions.negative
        return (label: "From Home", value: "\(amount) \(direction) of home")
    }
}
