//
//  VisitLog.swift
//  GeoRecords
//
//  When a region visit counts as an arrival, for the "Visited 14 times · last
//  Aug 2026" line. Live tracking fires on every significant location change, so
//  counting days would make the home state climb daily; instead a live fix counts
//  when its region differs from the previous fix's region of the same kind, and
//  a photo, manual or wizard entry counts on a day with no earlier visit.
//

import Foundation

enum VisitLog {
    struct Key: Hashable {
        let regionType: String   // "state", "country", "continent"
        let regionCode: String   // the record row's normalized code
    }

    static func key(code: String, type: RecordType) -> Key {
        switch type {
        case .state: return Key(regionType: "state", regionCode: normalizeRegionCode(code, isState: true))
        case .country: return Key(regionType: "country", regionCode: code)
        default: return Key(regionType: "continent", regionCode: code)
        }
    }

    static func shouldLogArrival(previousRegionCode: String?,
                                 newRegionCode: String,
                                 existingDates: [Date],
                                 date: Date,
                                 source: RecordSource,
                                 calendar: Calendar = .current) -> Bool {
        if source == .location {
            return previousRegionCode != newRegionCode
        }
        return !existingDates.contains { calendar.isDate($0, inSameDayAs: date) }
    }

    static func summary(dates: [Date]) -> (count: Int, last: Date?) {
        (dates.count, dates.max())
    }

    /// "3 visits · last Aug 2026", "1 visit", or nil when nothing is logged
    static func text(count: Int, last: Date?) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return "1 visit" }
        let lastText = last.map { " · last \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? ""
        return "\(count) visits\(lastText)"
    }
}
