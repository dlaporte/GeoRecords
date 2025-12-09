import Foundation
import CoreLocation

/// Shared geocoding cache to prevent redundant reverse geocoding requests
/// Uses coordinate rounding to ~11 meter precision for cache key matching
actor GeocodingCache {
    private var cache: [String: String] = [:]

    func getCachedName(for coordinate: CLLocationCoordinate2D) -> String? {
        let key = cacheKey(for: coordinate)
        return cache[key]
    }

    func setCachedName(_ name: String, for coordinate: CLLocationCoordinate2D) {
        let key = cacheKey(for: coordinate)
        cache[key] = name
    }

    /// Generate cache key by rounding coordinates to ~11 meter precision
    private func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        let roundedLat = round(coordinate.latitude * 10000) / 10000
        let roundedLon = round(coordinate.longitude * 10000) / 10000
        return "\(roundedLat),\(roundedLon)"
    }
}

/// Shared global geocoding cache instance
let sharedGeocodingCache = GeocodingCache()
