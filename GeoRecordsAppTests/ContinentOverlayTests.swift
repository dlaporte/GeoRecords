//
//  ContinentOverlayTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
import MapKit
@testable import GeoRecords

struct ContinentOverlayTests {

    // Natural Earth's "Continent" features are mainland masses only: the Yucatán,
    // Central America, the Caribbean, Great Britain, the Philippines, Madagascar
    // and New Zealand all sit outside them. The outlines in continents.json are
    // built from the country coastlines instead, so each country's land is drawn
    // in the continent the app attributes its visits to.
    @Test func continentOverlaysCoverIslandsAndIsthmuses() async throws {
        let service = RegionLookupService.shared
        let cases: [(name: String, continent: Continent, lat: Double, lon: Double)] = [
            ("Cancún", .northAmerica, 21.16, -86.85),
            ("Guatemala City", .northAmerica, 14.63, -90.51),
            ("Panama City", .northAmerica, 8.98, -79.52),
            ("Havana", .northAmerica, 23.11, -82.37),
            ("Caguas, Puerto Rico", .northAmerica, 18.23, -66.04),
            ("Nassau", .northAmerica, 25.08, -77.34),
            ("Greenland ice sheet", .northAmerica, 72.00, -40.00),
            ("London", .europe, 51.50, -0.12),
            ("Reykjavík", .europe, 64.15, -21.94),
            ("Manila", .asia, 14.60, 121.00),
            ("Jakarta", .asia, -6.20, 106.80),
            ("Antananarivo", .africa, -18.90, 47.50),
            ("Auckland", .oceania, -36.85, 174.76),
            ("Buenos Aires", .southAmerica, -34.60, -58.40)
        ]
        for c in cases {
            let coordinate = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
            #expect(service.continentPolygonsContain(coordinate, continent: c.continent),
                    "\(c.name) should be inside the \(c.continent.rawValue) overlay")
        }
    }

    // Russia, Kazakhstan and Turkey are cut along the Europe/Asia divide (Urals,
    // Ural River, Caspian, Caucasus crest, Bosporus), and overseas territories
    // land in the continent the app attributes them to
    @Test func continentOutlinesAreGeographic() async throws {
        let service = RegionLookupService.shared
        let cases: [(name: String, continent: Continent, lat: Double, lon: Double)] = [
            ("Moscow", .europe, 55.75, 37.62),
            ("Perm", .europe, 58.0, 56.23),
            ("Uralsk", .europe, 51.37, 51.23),
            ("Istanbul, European side", .europe, 41.03, 28.95),
            ("Yekaterinburg", .asia, 56.84, 60.6),
            ("Khabarovsk", .asia, 48.48, 135.07),
            ("Almaty", .asia, 43.2, 76.9),
            ("Istanbul, Asian side", .asia, 41.0, 29.05),
            ("Cayenne", .southAmerica, 4.93, -52.33),
            ("Nouméa", .oceania, -22.27, 166.45),
            ("Las Palmas", .europe, 28.12, -15.43),
            ("Honolulu", .northAmerica, 21.3, -157.86)
        ]
        for c in cases {
            let coordinate = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
            #expect(service.continentPolygonsContain(coordinate, continent: c.continent),
                    "\(c.name) should be inside the \(c.continent.rawValue) outline")
        }
        #expect(!service.continentPolygonsContain(CLLocationCoordinate2D(latitude: 55.75, longitude: 37.62), continent: .asia))
        #expect(!service.continentPolygonsContain(CLLocationCoordinate2D(latitude: 48.48, longitude: 135.07), continent: .europe))
    }

    // The outline is the countries' coast, not their borders: fewer vertices than
    // the countries combined, exterior rings only, every vertex on the globe
    @Test func continentOutlinesCarryNoCountryBorders() async throws {
        let service = RegionLookupService.shared
        let countryVertices = service.allCountries
            .filter { $0.continent == .europe }
            .map { service.polygons(for: $0.code).flatMap { $0 }.reduce(0) { $0 + $1.count } }
            .reduce(0, +)
        let europe = service.continentPolygons(for: .europe)
        let outlineVertices = europe.flatMap { $0 }.reduce(0) { $0 + $1.count }
        #expect(outlineVertices > 0 && outlineVertices < countryVertices)

        for continent in Continent.allCases {
            let polygons = service.continentPolygons(for: continent)
            #expect(!polygons.isEmpty, "\(continent.rawValue) has no outline")
            #expect(polygons.allSatisfy { $0.count == 1 }, "\(continent.rawValue) outline carries holes")
            let offGlobe = polygons.flatMap { $0.flatMap { $0 } }.filter { abs($0.latitude) > 90 || abs($0.longitude) > 180 }
            #expect(offGlobe.isEmpty, "\(continent.rawValue) has \(offGlobe.count) vertices off the globe")
        }
    }

    // The countries file labels a few island nations "Seven seas (open ocean)";
    // those fall back to the app's own country-to-continent table instead of
    // having no continent at all
    @Test func openOceanCountriesFallBackToTheAppContinentTable() async throws {
        let countries = RegionLookupService.shared.allCountries
        #expect(countries.first { $0.code == "SC" }?.continent == .africa)
        #expect(countries.first { $0.code == "MV" }?.continent == .asia)
        #expect(countries.first { $0.code == "MU" }?.continent == .africa)
    }

    // The North America mainland crosses the antimeridian through the Aleutians (as
    // do the United States, Russia and New Zealand), so a plain min/max bounding box
    // spans the globe and centers the camera on the prime meridian. Framing measures
    // longitude around the globe instead.
    @MainActor
    @Test func continentCamerasCenterOnTheContinent() async throws {
        let fallback = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                          span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
        let cache = RegionOverlayCache.shared

        let northAmerica = cache.cameraRegion(for: .northAmerica, defaultRegion: fallback)
        #expect(northAmerica.center.longitude > -140 && northAmerica.center.longitude < -60)

        let europe = cache.cameraRegion(for: .europe, defaultRegion: fallback)
        #expect(europe.span.longitudeDelta < 180)
        #expect(europe.center.longitude > -10 && europe.center.longitude < 70)

        let oceania = cache.cameraRegion(for: .oceania, defaultRegion: fallback)
        #expect(oceania.span.longitudeDelta < 180)
        #expect(oceania.span.longitudeDelta > 1, "Oceania camera fell back to the default")
    }

    // Natural Earth's antimeridian cuts leave a few vertices at 180.0000000000002°
    // (Russia, Fiji, Antarctica). CLLocationCoordinate2DIsValid rejects those and
    // MKPolygon maps them to map point (-1, -1), the world's top-left corner, so
    // the ring drew a line to the Arctic and filled the triangle on the way.
    @MainActor
    @Test func overlayVerticesStayInsideTheWorld() async throws {
        let cache = RegionOverlayCache.shared
        for continent in [Continent.europe, .oceania] {
            let strays = cache.multiPolygon(for: continent).polygons
                .filter { $0.boundingMapRect.minX < 0 || $0.boundingMapRect.minY < 0 }
            #expect(strays.isEmpty, "\(continent.rawValue) has \(strays.count) polygons reaching outside the map")
        }
        for code in ["RU", "FJ"] {
            let strays = cache.polygons(for: code, title: nil)
                .filter { $0.boundingMapRect.minX < 0 || $0.boundingMapRect.minY < 0 }
            #expect(strays.isEmpty, "\(code) has \(strays.count) polygons reaching outside the map")
        }
    }

    // MKMapView silently stops drawing whole tiles of a multipolygon overlay whose
    // polygons carry interior polygons (bisected in the simulator, Nov 2026), so
    // the map overlays are exterior rings only
    @MainActor
    @Test func mapOverlaysCarryNoInteriorPolygons() async throws {
        let cache = RegionOverlayCache.shared
        for continent in [Continent.asia, .europe, .africa] {
            let polygons = cache.multiPolygon(for: continent).polygons
            #expect(!polygons.isEmpty)
            #expect(polygons.allSatisfy { ($0.interiorPolygons ?? []).isEmpty }, "\(continent.rawValue) overlay has holes")
        }
        #expect(cache.polygons(for: "ZA", title: nil).allSatisfy { ($0.interiorPolygons ?? []).isEmpty })
    }

    @Test func longitudeExtentWrapsAcrossTheAntimeridian() async throws {
        // Plain range
        let plain = try #require(longitudeExtent(of: [-10, 5, 20]))
        #expect(plain.min == -10 && plain.max == 20)

        // Aleutians (170…180) plus Alaska to Greenland (-170…-20): the empty gap is
        // -20…170, so the range runs 170 → 340 and centers in the Americas
        let wrapped = try #require(longitudeExtent(of: [170, 179, -170, -100, -20]))
        #expect(wrapped.min == 170 && wrapped.max == 340)
        #expect(longitudeExtent(of: []) == nil)
    }
}
