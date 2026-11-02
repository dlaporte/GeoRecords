//
//  ContinentUnion.swift
//  GeoRecords
//
//  The outline of a continent from the polygons of its countries. The countries
//  tile the land without overlapping and share their borders vertex for vertex
//  (Natural Earth cuts them from one set of boundary lines), so every border
//  between two of them appears twice, once in each direction. Dropping those pairs
//  leaves exactly the coast (plus the borders with other continents), which chains
//  back into closed rings. Exact, no geometry library, and cheap enough to run
//  once at load: North America is 145k edges.
//

import Foundation
import CoreLocation

enum ContinentUnion {

    /// A vertex, matched at 1e-7° (about a centimetre). Shared vertices in the data
    /// differ by up to 1e-13° between neighbours (Lesotho's border and South
    /// Africa's hole share no vertex bit for bit), while nothing real is that close.
    struct Point: Hashable {
        let latitude: Double
        let longitude: Double

        init(_ coordinate: CLLocationCoordinate2D) {
            latitude = (coordinate.latitude * 1e7).rounded() / 1e7
            longitude = (coordinate.longitude * 1e7).rounded() / 1e7
        }

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private struct Edge: Hashable {
        let from: Point
        let to: Point
        var reversed: Edge { Edge(from: to, to: from) }
    }

    /// The polygons of the union, each as its rings: exterior first, then any holes
    /// (land around water that belongs to no country). Input polygons are rings
    /// too, exterior first; a hole in the input is an enclave, and cancels against
    /// the enclave's own exterior.
    static func polygons(of polygons: [[[CLLocationCoordinate2D]]]) -> [[[CLLocationCoordinate2D]]] {
        // Natural Earth winds exteriors clockwise; a ring around a surrounded
        // non-country area is walked the other way
        var exteriors: [[CLLocationCoordinate2D]] = []
        var holes: [[CLLocationCoordinate2D]] = []
        for ring in outlineRings(of: polygons) {
            if signedArea(of: ring) <= 0 {
                exteriors.append(ring)
            } else {
                holes.append(ring)
            }
        }
        var result = exteriors.map { [$0] }
        for hole in holes {
            guard let first = hole.first,
                  let index = exteriors.firstIndex(where: { contains($0, first) }) else { continue }
            result[index].append(hole)
        }
        return result
    }

    /// Every ring of the outline, in the input's winding, in no particular order
    static func outlineRings(of polygons: [[[CLLocationCoordinate2D]]]) -> [[CLLocationCoordinate2D]] {
        var edges = Set<Edge>()
        for polygon in polygons {
            for ring in polygon where ring.count > 2 {
                let points = ring.map(Point.init)
                for i in 0..<points.count {
                    let from = points[i]
                    let to = points[(i + 1) % points.count]
                    if from != to { edges.insert(Edge(from: from, to: to)) }
                }
            }
        }

        // Shared borders cancel; the rest is indexed by start point for chaining
        var next: [Point: [Point]] = [:]
        for edge in edges where !edges.contains(edge.reversed) {
            next[edge.from, default: []].append(edge.to)
        }

        // Every vertex has as many edges in as out, so a walk can only end where it
        // started: each walk is one closed ring. Walks begin at vertices with a
        // single way out; where two rings touch at a vertex, the sharpest right
        // turn keeps the land on the right and each ring simple.
        let starts = next.keys.sorted {
            (next[$0]?.count ?? 0, $0.longitude, $0.latitude) < (next[$1]?.count ?? 0, $1.longitude, $1.latitude)
        }
        var rings: [[CLLocationCoordinate2D]] = []
        for start in starts where next[start] != nil {
            var ring = [start.coordinate]
            var previous: Point?
            var current = start
            while let candidates = next[current] {
                let index = candidates.count == 1 ? 0 : sharpestRightTurn(from: previous, at: current, among: candidates)
                let to = candidates[index]
                if candidates.count == 1 {
                    next[current] = nil
                } else {
                    next[current]?.remove(at: index)
                }
                if to == start { break }
                ring.append(to.coordinate)
                previous = current
                current = to
            }
            if ring.count > 2 { rings.append(ring) }
        }
        return rings
    }

    /// Index of the candidate that turns most sharply right from the direction of
    /// travel (a U-turn counts as the least right)
    private static func sharpestRightTurn(from previous: Point?, at current: Point, among candidates: [Point]) -> Int {
        guard let previous else { return 0 }
        let dx = current.longitude - previous.longitude
        let dy = current.latitude - previous.latitude
        var best = 0
        var bestTurn = Double.infinity
        for (index, candidate) in candidates.enumerated() {
            let vx = candidate.longitude - current.longitude
            let vy = candidate.latitude - current.latitude
            let turn = atan2(dx * vy - dy * vx, dx * vx + dy * vy)  // negative = right
            if turn < bestTurn {
                bestTurn = turn
                best = index
            }
        }
        return best
    }

    /// Shoelace area in degrees²: negative for clockwise rings
    static func signedArea(of ring: [CLLocationCoordinate2D]) -> Double {
        var sum = 0.0
        for i in 0..<ring.count {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            sum += a.longitude * b.latitude - b.longitude * a.latitude
        }
        return sum / 2
    }

    /// Ray casting, for assigning holes to the exterior around them
    static func contains(_ ring: [CLLocationCoordinate2D], _ point: CLLocationCoordinate2D) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i]
            let b = ring[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude),
               point.longitude < (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
