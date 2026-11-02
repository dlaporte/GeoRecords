//
//  ContinentUnionTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

struct ContinentUnionTests {

    /// A clockwise square, wound like Natural Earth's exteriors
    private func square(_ lon0: Double, _ lon1: Double, _ lat0: Double, _ lat1: Double) -> [CLLocationCoordinate2D] {
        [CLLocationCoordinate2D(latitude: lat0, longitude: lon0), CLLocationCoordinate2D(latitude: lat1, longitude: lon0),
         CLLocationCoordinate2D(latitude: lat1, longitude: lon1), CLLocationCoordinate2D(latitude: lat0, longitude: lon1)]
    }

    /// A counterclockwise square, wound like a hole
    private func hole(_ lon0: Double, _ lon1: Double, _ lat0: Double, _ lat1: Double) -> [CLLocationCoordinate2D] {
        Array(square(lon0, lon1, lat0, lat1).reversed())
    }

    // Two countries sharing a border become one ring: the border is gone, the
    // coast keeps every vertex
    @Test func sharedBordersCancel() async throws {
        let union = ContinentUnion.polygons(of: [[square(0, 1, 0, 1)], [square(1, 2, 0, 1)]])
        #expect(union.count == 1)
        let outline = try #require(union.first?.first)
        #expect(outline.count == 6)
        #expect(ContinentUnion.signedArea(of: outline) < 0)
        #expect(ContinentUnion.contains(outline, CLLocationCoordinate2D(latitude: 0.5, longitude: 1)), "the old border is inside")
        for i in 0..<outline.count {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            #expect(!(a.longitude == 1 && b.longitude == 1), "no edge runs along the old border")
        }
    }

    // An enclave fills its parent's hole and vanishes; a lake stays a hole of the
    // land around it
    @Test func enclavesMergeAndLakesStayHoles() async throws {
        let filled = ContinentUnion.polygons(of: [[square(3, 5, 0, 2), hole(3.5, 4.5, 0.5, 1.5)], [square(3.5, 4.5, 0.5, 1.5)]])
        #expect(filled.count == 1)
        #expect(filled.first?.count == 1)
        #expect(filled.first?.first?.count == 4)

        let lake = ContinentUnion.polygons(of: [[square(6, 8, 0, 2), hole(6.5, 7.5, 0.5, 1.5)]])
        #expect(lake.count == 1)
        #expect(lake.first?.count == 2)
        #expect(ContinentUnion.signedArea(of: lake[0][1]) > 0)
    }

    // Two countries touching at a single point stay two rings: at the junction the
    // walk takes the sharpest right turn instead of wandering into the other ring
    @Test func touchingRingsStaySeparate() async throws {
        let union = ContinentUnion.polygons(of: [[square(0, 1, 0, 1)], [square(1, 2, 1, 2)]])
        #expect(union.count == 2)
        #expect(union.allSatisfy { $0.count == 1 && $0[0].count == 4 })
    }

    // Lesotho sits in a hole of South Africa's polygon: in the Africa outline no
    // vertex of its border survives, and Maseru is simply inside Africa
    @Test func lesothoDisappearsIntoAfrica() async throws {
        let service = RegionLookupService.shared
        let borderVertex = try #require(service.polygons(for: "LS").first?.first?.first)
        let africa = service.continentPolygons(for: .africa)
        let vertices = Set(africa.flatMap { $0.flatMap { $0.map(ContinentUnion.Point.init) } })
        #expect(!vertices.contains(ContinentUnion.Point(borderVertex)))
        let maseru = CLLocationCoordinate2D(latitude: -29.31, longitude: 27.48)
        #expect(africa.contains { ContinentUnion.contains($0[0], maseru) })
    }

    // The continent outline is the countries' coast, not their borders: fewer
    // vertices than the countries combined, and the isthmus and islands stay inside
    @Test func continentOutlineKeepsTheCoastAndDropsTheBorders() async throws {
        let service = RegionLookupService.shared
        let countryVertices = service.allCountries
            .filter { $0.continent == .northAmerica }
            .map { service.polygons(for: $0.code).flatMap { $0 }.reduce(0) { $0 + $1.count } }
            .reduce(0, +)
        let northAmerica = service.continentPolygons(for: .northAmerica)
        let unionVertices = northAmerica.flatMap { $0 }.reduce(0) { $0 + $1.count }
        #expect(unionVertices < countryVertices)
        for (name, lat, lon) in [("Guatemala City", 14.63, -90.51), ("Cancún", 21.16, -86.85), ("Havana", 23.11, -82.37), ("Winnipeg", 49.9, -97.14)] {
            let point = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            #expect(northAmerica.contains { ContinentUnion.contains($0[0], point) }, "\(name) should be inside the North America outline")
        }
    }
}
