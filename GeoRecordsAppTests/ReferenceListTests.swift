//
//  ReferenceListTests.swift
//  GeoRecordsTests
//

import Testing
@testable import GeoRecords

struct ReferenceListTests {

    // The Countries "Not yet" list and Siri's region entity use a fixed list of the
    // 193 UN members plus Vatican City and Palestine, matching the "of 195" the app
    // already shows
    @Test func unCountryListHas195UniqueCodes() async throws {
        #expect(unMemberAndObserverCountries.count == 195)
        #expect(Set(unMemberAndObserverCountries.map(\.code)).count == 195)
        #expect(unMemberAndObserverCountries.allSatisfy { $0.code.count == 2 && $0.code == $0.code.uppercased() })
        #expect(unMemberAndObserverCountries.contains { $0.code == "VA" })
        #expect(unMemberAndObserverCountries.contains { $0.code == "PS" })
    }

    @Test func everyListedCountryHasAMapPolygon() async throws {
        let missing = unMemberAndObserverCountries.filter { RegionLookupService.shared.polygons(for: $0.code).isEmpty }.map(\.code)
        #expect(missing.isEmpty, "no polygon for \(missing)")
    }

    @Test func stateNamesCoverStatesDCAndPuertoRico() async throws {
        #expect(usStateNames.count == 52)
        #expect(usStateNames["WA"] == "Washington")
        #expect(usStateNames["DC"] == "District of Columbia")
        #expect(usStateNames["PR"] == "Puerto Rico")
        #expect(Set(usStateNames.keys).isSuperset(of: usStatePostalCodes))
    }
}
