//
//  RecordCaption.swift
//  GeoRecords
//
//  The one secondary line under a record card's value, and the detail view's
//  "Beat previous by" row. Precedence on a card: within-reach (current-month
//  cards only), then progression, then nothing.
//

import Foundation

/// Which slot a card is standing in, passed by the Records tab. Nil elsewhere.
struct RecordCardContext: Equatable {
    let slotTimeFrame: TimeFrame
    let isCurrentPeriod: Bool
}

enum RecordCaption {
    private static let monthYear: Date.FormatStyle = .dateTime.month(.abbreviated).year()

    /// "Beat previous by 212 mi" for the card; nil when nothing was beaten
    static func progression(current: RecordDetail, previous: RecordDetail?, unitSystem: UnitSystem) -> String? {
        guard let amount = progressionAmount(current: current, previous: previous, unitSystem: unitSystem) else { return nil }
        return "Beat previous by \(amount)"
    }

    /// "212 mi (Tromsø, Jun 2024)" for the detail row
    static func progressionDetail(current: RecordDetail, previous: RecordDetail?, unitSystem: UnitSystem) -> String? {
        guard let previous,
              let amount = progressionAmount(current: current, previous: previous, unitSystem: unitSystem) else { return nil }
        let when = previous.timestamp.formatted(monthYear)
        if let name = previous.locationName, !name.isEmpty, name != unknownLocationString {
            return "\(amount) (\(name), \(when))"
        }
        return "\(amount) (\(when))"
    }

    private static func progressionAmount(current: RecordDetail, previous: RecordDetail?, unitSystem: UnitSystem) -> String? {
        guard let previous,
              let type = RecordType.from(string: current.recordType),
              let meters = RecordDelta.meters(type: type, from: previous.value, to: current.value,
                                              atLatitude: current.coordinate.latitude),
              meters > 0 else { return nil }
        return RecordDelta.format(meters: meters, type: type, unitSystem: unitSystem)
    }

    /// How close a monthly value has to be before the card mentions the bigger
    /// record: 100 mi for distances and degrees, 1,000 ft for elevation
    static func reachThresholdMeters(for type: RecordType) -> Double {
        type == .up ? 305 : 160_934
    }

    /// "15 mi short of your yearly furthest east". The yearly slot is the target
    /// when it is ahead of the month; when the month IS the yearly record, the
    /// lifetime slot is. Nil when the month leads or the gap is beyond reach.
    static func withinReach(month: RecordDetail, year: RecordDetail?, lifetime: RecordDetail?, unitSystem: UnitSystem) -> String? {
        guard let type = RecordType.from(string: month.recordType), type.isGeographicExtreme else { return nil }
        let targets: [(label: String, record: RecordDetail?)] = [("yearly", year), ("lifetime", lifetime)]
        for (label, target) in targets {
            guard let target, type.shouldReplace(newValue: target.value, oldValue: month.value) else { continue }
            guard let meters = RecordDelta.meters(type: type, from: month.value, to: target.value,
                                                  atLatitude: month.coordinate.latitude),
                  meters > 0, meters <= reachThresholdMeters(for: type) else { return nil }
            let amount = RecordDelta.format(meters: meters, type: type, unitSystem: unitSystem)
            return "\(amount) short of your \(label) \(type.rawValue.lowercased())"
        }
        return nil
    }
}
