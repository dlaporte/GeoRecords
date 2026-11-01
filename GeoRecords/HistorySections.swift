//
//  HistorySections.swift
//  GeoRecords
//
//  Month sections for the History list (rows keep their flat index, which the
//  detail pager uses) and the Source filter.
//

import Foundation

struct HistoryRow: Identifiable {
    /// Position in the flat filtered list, the index HistoryDetailPager opens at
    let index: Int
    let entry: RecordHistoryEntry
    var id: Int { index }
}

struct HistorySection: Identifiable {
    let id: String
    let title: String
    let rows: [HistoryRow]
}

enum HistorySections {
    /// Groups an already-sorted (newest first) list by calendar month; rows without
    /// a timestamp land in an "Undated" section
    static func group(_ entries: [RecordHistoryEntry], calendar: Calendar = .current) -> [HistorySection] {
        var sections: [HistorySection] = []
        var currentKey: String?
        var currentTitle = ""
        var currentRows: [HistoryRow] = []

        func flush() {
            if let key = currentKey {
                sections.append(HistorySection(id: key, title: currentTitle, rows: currentRows))
            }
        }

        for (index, entry) in entries.enumerated() {
            let key: String
            let title: String
            if let timestamp = entry.timestamp {
                let components = calendar.dateComponents([.year, .month], from: timestamp)
                key = "\(components.year ?? 0)-\(components.month ?? 0)"
                title = timestamp.formatted(.dateTime.month(.wide).year())
            } else {
                key = "undated"
                title = "Undated"
            }
            if key != currentKey {
                flush()
                currentKey = key
                currentTitle = title
                currentRows = []
            }
            currentRows.append(HistoryRow(index: index, entry: entry))
        }
        flush()
        return sections
    }
}

/// The History "Source" menu: every stored source plus a bucket for rows with none
enum HistorySourceFilter: Hashable {
    case all
    case source(RecordSource)
    case unknown

    static let menuOrder: [HistorySourceFilter] =
        [.all] + [RecordSource.location, .photo, .wizard, .manual, .home].map { .source($0) } + [.unknown]

    var title: String {
        switch self {
        case .all: return "All Sources"
        case .source(let source): return source.displayName
        case .unknown: return "Unknown"
        }
    }

    func matches(_ raw: String?) -> Bool {
        switch self {
        case .all: return true
        case .source(let source): return raw == source.rawValue
        case .unknown: return raw.flatMap(RecordSource.init(rawValue:)) == nil
        }
    }
}
