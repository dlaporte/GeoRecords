//
//  RecordHistoryQueries.swift
//  GeoRecords
//
//  Read-mostly history queries behind the progression row, the Stats
//  "records set" counts and the home recalculation. Every query takes its
//  context so tests can run it against an in-memory store.
//

import Foundation
import CoreData
import CoreLocation

/// One "record set" moment: a type beaten (or first set) at an instant. One location
/// event writes a row per timeframe it beats, all with the same timestamp, so
/// events are keyed on (type, second), never counted per row.
struct RecordEvent: Hashable {
    let recordType: RecordType
    let timestamp: Date
}

extension RecordHistoryManager {

    /// The record this one beat: the latest less-extreme row of the same type in the
    /// same slot period. The candidate rows mirror what `loadRecordsFromHistory`
    /// fills each slot from, so `current.timeFrame` must be the slot the record is
    /// shown in (Month: Monthly rows of its month; Year: Yearly and Monthly rows of
    /// its year; Lifetime: lifetime-tagged rows). Rows at home never count.
    nonisolated static func previousRecord(before current: RecordDetail,
                                           home: CLLocationCoordinate2D?,
                                           in context: NSManagedObjectContext) -> RecordDetail? {
        guard let type = RecordType.from(string: current.recordType), type.isGeographicExtreme else { return nil }
        let calendar = Calendar.current
        var predicates = [
            NSPredicate(format: "recordType == %@", current.recordType),
            // Skip the sibling rows the same event wrote (same timestamp)
            NSPredicate(format: "timestamp < %@", current.timestamp.addingTimeInterval(-1) as NSDate)
        ]
        switch current.timeFrame {
        case .month:
            guard let period = calendar.dateInterval(of: .month, for: current.timestamp) else { return nil }
            predicates.append(NSPredicate(format: "timeFrame == %@", TimeFrame.month.rawValue))
            predicates.append(NSPredicate(format: "timestamp >= %@", period.start as NSDate))
        case .year:
            guard let period = calendar.dateInterval(of: .year, for: current.timestamp) else { return nil }
            predicates.append(NSPredicate(format: "timeFrame IN %@", [TimeFrame.year.rawValue, TimeFrame.month.rawValue]))
            predicates.append(NSPredicate(format: "timestamp >= %@", period.start as NSDate))
        case .allTime, .daily:
            predicates.append(NSPredicate(format: "timeFrame IN %@", lifetimeTimeFrameVariations))
        }

        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        guard let rows = try? context.fetch(request) else { return nil }

        for row in rows {
            if isAtHome(row, home: home) { continue }
            if type.shouldReplace(newValue: current.value, oldValue: row.value) {
                return RecordDetail(from: row)
            }
        }
        return nil
    }

    /// Records set inside an interval: geographic extremes only, Monthly/Yearly/
    /// Lifetime rows (never the per-day rows), never at home, one event per type
    /// and second. Sorted by time.
    nonisolated static func recordEvents(in interval: DateInterval,
                                         home: CLLocationCoordinate2D?,
                                         in context: NSManagedObjectContext) -> [RecordEvent] {
        let types = RecordType.allCases.filter(\.isGeographicExtreme).map(\.rawValue)
        let timeFrames = [TimeFrame.month.rawValue, TimeFrame.year.rawValue] + lifetimeTimeFrameVariations
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "recordType IN %@ AND timeFrame IN %@ AND timestamp >= %@ AND timestamp < %@",
            types, timeFrames, interval.start as NSDate, interval.end as NSDate
        )
        guard let rows = try? context.fetch(request) else { return [] }

        var events = Set<RecordEvent>()
        for row in rows {
            guard let type = RecordType.from(string: row.recordType ?? ""),
                  let timestamp = row.timestamp,
                  !isAtHome(row, home: home) else { continue }
            let second = Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded())
            events.insert(RecordEvent(recordType: type, timestamp: second))
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// Rewrite every "Furthest from Home" row (all timeframes) from its stored
    /// coordinates against a new home. Returns the number of rows touched. The
    /// caller reloads the in-memory slots afterwards.
    nonisolated static func recalculateFromHomeRecords(home: CLLocationCoordinate2D,
                                                       in context: NSManagedObjectContext) throws -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "recordType == %@", RecordType.fromHome.rawValue)
        let rows = try context.fetch(request)
        for row in rows {
            let coordinate = CLLocationCoordinate2D(latitude: row.latitude, longitude: row.longitude)
            row.value = distanceBetween(from: coordinate, to: home)
        }
        if context.hasChanges { try context.save() }
        return rows.count
    }

    private nonisolated static func isAtHome(_ row: RecordHistoryEntry, home: CLLocationCoordinate2D?) -> Bool {
        guard let home else { return false }
        let coordinate = CLLocationCoordinate2D(latitude: row.latitude, longitude: row.longitude)
        return distanceBetween(from: coordinate, to: home) <= atHomeRadiusMeters
    }

    // MARK: - Conveniences on the shared store and current home

    func previousRecord(before current: RecordDetail) -> RecordDetail? {
        Self.previousRecord(before: current,
                            home: SettingsManager.shared.homeCoordinate,
                            in: PersistenceController.shared.container.viewContext)
    }

    func recordEvents(in interval: DateInterval) -> [RecordEvent] {
        Self.recordEvents(in: interval,
                          home: SettingsManager.shared.homeCoordinate,
                          in: PersistenceController.shared.container.viewContext)
    }

    func recalculateFromHomeRecords(home: CLLocationCoordinate2D) throws -> Int {
        try Self.recalculateFromHomeRecords(home: home, in: PersistenceController.shared.container.viewContext)
    }

    /// How many "Furthest from Home" rows exist (whether the recalculate prompt applies)
    func fromHomeRowCount() -> Int {
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "recordType == %@", RecordType.fromHome.rawValue)
        return (try? PersistenceController.shared.container.viewContext.count(for: request)) ?? 0
    }
}
