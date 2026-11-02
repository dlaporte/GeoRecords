//
//  ContinentAttributionTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

// Continents are geographic (continents.json): a visit inside Russia, Kazakhstan
// or Turkey counts for the continent whose outline contains it, everywhere else
// the country's continent still applies
struct ContinentAttributionTests {

    private func region(_ lat: Double, _ lon: Double) -> RegionInfo? {
        RegionLookupService.shared.region(for: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    @Test func dividedCountriesFollowTheEuropeAsiaDivide() async throws {
        let cases: [(name: String, lat: Double, lon: Double, code: String, continent: Continent)] = [
            ("Moscow", 55.75, 37.62, "RU", .europe),
            ("Perm", 58.0, 56.23, "RU", .europe),
            ("Yekaterinburg", 56.84, 60.6, "RU", .asia),
            ("Khabarovsk", 48.48, 135.07, "RU", .asia),
            ("Uralsk", 51.37, 51.23, "KZ", .europe),
            ("Almaty", 43.2, 76.9, "KZ", .asia),
            ("Istanbul, European side", 41.03, 28.95, "TR", .europe),
            ("Istanbul, Asian side", 41.0, 29.05, "TR", .asia),
            ("Ankara", 39.93, 32.85, "TR", .asia)
        ]
        for c in cases {
            let info = try #require(region(c.lat, c.lon), "\(c.name) should resolve")
            #expect(info.code == c.code, "\(c.name) country")
            #expect(info.continent == c.continent, "\(c.name) continent")
        }
    }

    @Test func undividedCountriesKeepTheirContinent() async throws {
        let tbilisi = try #require(region(41.7, 44.8))
        #expect(tbilisi.code == "GE" && tbilisi.continent == .asia)
        let cairo = try #require(region(30.04, 31.24))
        #expect(cairo.code == "EG" && cairo.continent == .africa)
        let paris = try #require(region(48.86, 2.35))
        #expect(paris.code == "FR" && paris.continent == .europe)
    }

    // Harbour fixes sit just offshore of the 10m coastline. Vladivostok's waterfront
    // is still Russia by the coastal tolerance, and still Asia, not open water
    // falling back to Europe
    @Test func fixesJustOffTheCoastStillFollowTheDivide() async throws {
        let waterfront = try #require(region(43.10, 131.90))
        #expect(waterfront.code == "RU")
        #expect(waterfront.continent == .asia)
    }

    // The live-fix and photo paths chain a continent record off the country
    // record through this rule, so it must follow the outline too
    @Test func countryVisitsChainTheContinentFromTheFix() async throws {
        let service = RegionLookupService.shared
        #expect(service.continent(forCountryCode: "RU", at: CLLocationCoordinate2D(latitude: 48.48, longitude: 135.07)) == .asia)
        #expect(service.continent(forCountryCode: "RU", at: CLLocationCoordinate2D(latitude: 55.75, longitude: 37.62)) == .europe)
        #expect(service.continent(forCountryCode: "TR", at: CLLocationCoordinate2D(latitude: 41.03, longitude: 28.95)) == .europe)
        // Open water inside a divided country's record (mid-Caspian) falls back to the code's continent
        #expect(service.continent(forCountryCode: "RU", at: CLLocationCoordinate2D(latitude: 44.0, longitude: 48.5)) == .europe)
        // Undivided codes ignore the fix, territories included
        #expect(service.continent(forCountryCode: "JP", at: CLLocationCoordinate2D(latitude: 0, longitude: 0)) == .asia)
        #expect(service.continent(forCountryCode: "PT-20", at: CLLocationCoordinate2D(latitude: 37.74, longitude: -25.67)) == .europe)
    }

    @Test func regionCodesMapToTheirContinent() async throws {
        let service = RegionLookupService.shared
        #expect(service.continent(forRegionCode: "US-WA") == .northAmerica)
        #expect(service.continent(forRegionCode: "JP") == .asia)
        #expect(service.continent(forRegionCode: "GF") == .southAmerica)
        #expect(service.continent(forRegionCode: "PT-20") == .europe)
        #expect(service.continent(forRegionCode: "CX") == .oceania)
        #expect(service.continent(forRegionCode: "SC") == .africa)
        #expect(service.continent(forRegionCode: "ZZ") == nil)
    }
}
