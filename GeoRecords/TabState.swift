//
//  TabState.swift
//  GeoRecords
//
//  Per-tab selection and filters, owned by ContentView and shared by a tab's
//  compact (iPhone) and regular (iPad, iPhone Duo open) layouts. Hoisting them
//  out of the views means a fold, a Split View resize or a rotation that swaps
//  layouts keeps what the user had selected.
//

import Foundation
import Observation

@Observable
final class RecordsTabState {
    var timeFrame: TimeFrame = .allTime
    var year: Int?
    var month: MonthSelection?
    /// The record the regular-width detail column shows (nil = first record)
    var selectedRecordID: UUID?

    /// A widget or notification link targets the CURRENT period of a timeframe
    func apply(deepLinkTimeFrame: TimeFrame) {
        timeFrame = deepLinkTimeFrame
        year = nil
        month = nil
    }
}

/// What the Regions tab lists under the map (or in its sidebar): the region cards,
/// the regions still unvisited, or the visited regions as a dense list
enum RegionListMode: Equatable {
    case cards, notYet, visited

    /// The pill cycles cards → not yet → visited → cards
    var next: RegionListMode {
        switch self {
        case .cards: return .notYet
        case .notYet: return .visited
        case .visited: return .cards
        }
    }
}

@Observable
final class RegionsTabState {
    var mapType: MapsTabView.MapType = .states
    /// Region code of the selected card in the current map type (nil = first card)
    var selectedRegionCode: String?
    var listMode: RegionListMode = .cards
    /// The map draws the unvisited regions only while their list is up
    var showNotYet: Bool { listMode == .notYet }

    /// "states" / "countries" / "continents" from a deep link; anything else is ignored
    func apply(section: String) {
        switch section {
        case "states": mapType = .states
        case "countries": mapType = .countries
        case "continents": mapType = .continents
        default: break
        }
    }
}

@Observable
final class HistoryTabState {
    var searchText = ""
    var typeFilter: String = "All Types"
    var timeFrameFilter: String = "All Timeframes"
    var source: HistorySourceFilter = .all
    var includeHome = false
    /// The entry the regular-width detail column shows
    var selectedEntryID: UUID?
}

@Observable
final class StatsTabState {
    var timeFrame: TimeFrame = .allTime
    var year: Int?
    var month: MonthSelection?
}
