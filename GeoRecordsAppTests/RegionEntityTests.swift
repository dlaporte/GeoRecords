//
//  RegionEntityTests.swift
//  GeoRecordsTests
//

import Testing
import Foundation
@testable import GeoRecords

struct RegionEntityTests {

    @Test func regionEntitiesCoverStatesCountriesAndContinents() async throws {
        let all = RegionEntity.all()
        #expect(all.filter { $0.kind == .state }.count == 52)
        #expect(all.filter { $0.kind == .country }.count == 195)
        #expect(all.filter { $0.kind == .continent }.count == 7)
        #expect(all.first { $0.id == "state:NV" }?.code == "US-NV")

        // A visited country outside the 195 is added once
        let extra = RegionEntity.all(extraCountries: [(code: "TW", name: "Taiwan"), (code: "JP", name: "Japan")])
        #expect(extra.filter { $0.kind == .country }.count == 196)
    }

    @Test func regionMatchingPrefersExactNames() async throws {
        let all = RegionEntity.all()
        #expect(RegionEntity.matching("nevada", in: all).map(\.id) == ["state:NV"])
        #expect(RegionEntity.matching("new", in: all).count >= 5)
        #expect(RegionEntity.matching("   ", in: all).isEmpty)
    }

    @Test func visitedDialogsReadNaturally() async throws {
        #expect(VisitedRegionQueryIntent.visitedDialog(name: "Nevada", firstVisit: noon(2022, 6, 3), count: 3)
                == "Yes. You first visited Nevada in June 2022 and you've been there 3 times.")
        #expect(VisitedRegionQueryIntent.visitedDialog(name: "Nevada", firstVisit: noon(2022, 6, 3), count: 1)
                == "Yes. You visited Nevada in June 2022.")
        #expect(VisitedRegionQueryIntent.notVisitedDialog(name: "Nevada", kindName: "state", nextCount: 15)
                == "Not yet. Nevada would be your 15th state.")
    }
}
