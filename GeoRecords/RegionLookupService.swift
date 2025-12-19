import Foundation
import CoreLocation
import MapKit

// MARK: - Region Info

/// Information about a geographical region
struct RegionInfo {
    let code: String           // e.g., "US-CA", "FR"
    let name: String           // e.g., "California", "France"
    let type: RegionType       // .state or .country
    let continent: Continent?  // Only for countries
}

// MARK: - Region Boundary

/// Internal structure for region boundary data with bounding box optimization
struct RegionBoundary {
    let code: String
    let name: String
    let type: RegionType
    let continent: Continent?
    let boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    let polygons: [[[Double]]]  // Array of polygons, each polygon is array of [lon, lat] pairs

    /// Quick check if a point could possibly be in this region
    func containsInBoundingBox(latitude: Double, longitude: Double) -> Bool {
        return latitude >= boundingBox.minLat &&
               latitude <= boundingBox.maxLat &&
               longitude >= boundingBox.minLon &&
               longitude <= boundingBox.maxLon
    }

    /// Check if a point is within the bounding box with added tolerance
    func containsInBoundingBox(latitude: Double, longitude: Double, tolerance: Double) -> Bool {
        return latitude >= (boundingBox.minLat - tolerance) &&
               latitude <= (boundingBox.maxLat + tolerance) &&
               longitude >= (boundingBox.minLon - tolerance) &&
               longitude <= (boundingBox.maxLon + tolerance)
    }
}

// MARK: - Region Lookup Service

/// Service for looking up geographical regions from coordinates
/// Uses GeoJSON boundary data and point-in-polygon algorithm
class RegionLookupService {
    static let shared = RegionLookupService()

    private var usStates: [RegionBoundary] = []
    private var countries: [RegionBoundary] = []
    private var continents: [RegionBoundary] = []
    private var usOutlinePolylines: [[[Double]]] = []  // Array of LineStrings [lon, lat]
    private var isLoaded = false
    private let loadQueue = DispatchQueue(label: "com.georecords.regionLookup", qos: .userInitiated)

    private init() {}

    // MARK: - Public API

    /// Load boundary data from GeoJSON files (call once at startup or on first use)
    func loadBoundaries() {
        loadQueue.sync {
            guard !isLoaded else { return }

            loadUSStates()
            loadUSOutline()
            loadCountries()
            loadContinents()
            isLoaded = true

            debugLog("📍 RegionLookupService: Loaded \(usStates.count) states, \(usOutlinePolylines.count) outline segments, \(countries.count) countries, and \(continents.count) continents")
        }
    }

    /// Find the region for a given coordinate
    /// - Parameter coordinate: The location to look up
    /// - Returns: RegionInfo if found, nil if in international waters or unrecognized territory
    func region(for coordinate: CLLocationCoordinate2D) -> RegionInfo? {
        if !isLoaded {
            loadBoundaries()
        }

        let lat = coordinate.latitude
        let lon = coordinate.longitude

        // First check US states (more specific)
        for state in usStates {
            if state.containsInBoundingBox(latitude: lat, longitude: lon) {
                if pointInRegion(latitude: lat, longitude: lon, region: state) {
                    return RegionInfo(
                        code: "US-\(state.code)",
                        name: state.name,
                        type: .state,
                        continent: .northAmerica
                    )
                }
            }
        }

        // Then check countries
        for country in countries {
            if country.containsInBoundingBox(latitude: lat, longitude: lon) {
                if pointInRegion(latitude: lat, longitude: lon, region: country) {
                    return RegionInfo(
                        code: country.code,
                        name: country.name,
                        type: .country,
                        continent: country.continent
                    )
                }
            }
        }

        // If no exact match, check for coastal/border points within tolerance
        // This helps with points at ports, marinas, or simplified polygon boundaries
        // Tolerance of ~0.01° ≈ 1.1km at equator
        let coastalTolerance = 0.01

        // Check countries with expanded bounding box
        for country in countries {
            if country.containsInBoundingBox(latitude: lat, longitude: lon, tolerance: coastalTolerance) {
                if pointNearRegion(latitude: lat, longitude: lon, region: country, tolerance: coastalTolerance) {
                    return RegionInfo(
                        code: country.code,
                        name: country.name,
                        type: .country,
                        continent: country.continent
                    )
                }
            }
        }

        return nil
    }

    /// Get all polygon coordinates for a region (for map overlays)
    /// - Parameter regionCode: The region code (e.g., "US-CA", "FR")
    /// - Returns: Array of polygon coordinate arrays
    func polygons(for regionCode: String) -> [[[CLLocationCoordinate2D]]] {
        if !isLoaded {
            loadBoundaries()
        }

        // Check if it's a US state
        if regionCode.hasPrefix("US-") {
            let stateCode = String(regionCode.dropFirst(3))
            if let state = usStates.first(where: { $0.code == stateCode }) {
                return convertToCoordinates(polygons: state.polygons)
            }
        }

        // Check countries
        if let country = countries.first(where: { $0.code == regionCode }) {
            return convertToCoordinates(polygons: country.polygons)
        }

        return []
    }

    /// Get all loaded US states
    var allUSStates: [RegionInfo] {
        if !isLoaded { loadBoundaries() }
        return usStates.map { RegionInfo(code: "US-\($0.code)", name: $0.name, type: .state, continent: .northAmerica) }
    }

    /// Get all loaded countries
    var allCountries: [RegionInfo] {
        if !isLoaded { loadBoundaries() }
        return countries.map { RegionInfo(code: $0.code, name: $0.name, type: .country, continent: $0.continent) }
    }

    /// Get polygon coordinates for a continent (for map overlays)
    /// - Parameter continent: The continent enum value
    /// - Returns: Array of polygon coordinate arrays
    func continentPolygons(for continent: Continent) -> [[[CLLocationCoordinate2D]]] {
        if !isLoaded {
            loadBoundaries()
        }

        if let continentBoundary = continents.first(where: { $0.continent == continent }) {
            return convertToCoordinates(polygons: continentBoundary.polygons)
        }

        return []
    }

    /// Get US outline polylines (for map overlays)
    /// - Returns: Array of polyline coordinate arrays
    func getUSOutlinePolylines() -> [[CLLocationCoordinate2D]] {
        if !isLoaded {
            loadBoundaries()
        }

        return usOutlinePolylines.map { lineString in
            lineString.compactMap { point -> CLLocationCoordinate2D? in
                guard point.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
            }
        }
    }

    // MARK: - Private Loading Methods

    private func loadUSStates() {
        guard let url = Bundle.main.url(forResource: "gz_2010_us_040_00_5m", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            debugLog("⚠️ Failed to load gz_2010_us_040_00_5m.json")
            return
        }

        // US territory FIPS codes to exclude (not states)
        let territoryFIPS = Set(["60", "66", "69", "72", "78"])  // AS, GU, MP, PR, VI

        // FIPS code to postal code mapping (50 states only, excludes DC)
        let fipsToPostal: [String: String] = [
            "01": "AL", "02": "AK", "04": "AZ", "05": "AR", "06": "CA",
            "08": "CO", "09": "CT", "10": "DE", "12": "FL",
            "13": "GA", "15": "HI", "16": "ID", "17": "IL", "18": "IN",
            "19": "IA", "20": "KS", "21": "KY", "22": "LA", "23": "ME",
            "24": "MD", "25": "MA", "26": "MI", "27": "MN", "28": "MS",
            "29": "MO", "30": "MT", "31": "NE", "32": "NV", "33": "NH",
            "34": "NJ", "35": "NM", "36": "NY", "37": "NC", "38": "ND",
            "39": "OH", "40": "OK", "41": "OR", "42": "PA", "44": "RI",
            "45": "SC", "46": "SD", "47": "TN", "48": "TX", "49": "UT",
            "50": "VT", "51": "VA", "53": "WA", "54": "WV", "55": "WI",
            "56": "WY"
        ]

        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let name = properties["NAME"] as? String,
                  let fipsCode = properties["STATE"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let geometryType = geometry["type"] as? String,
                  let coordinates = geometry["coordinates"] as? [Any] else {
                continue
            }

            // Skip US territories - only include actual states (and DC)
            if territoryFIPS.contains(fipsCode) {
                continue
            }

            // Convert FIPS to postal code
            guard let postalCode = fipsToPostal[fipsCode] else {
                debugLog("⚠️ Unknown FIPS code: \(fipsCode) for \(name)")
                continue
            }

            let polygons = extractPolygons(geometryType: geometryType, coordinates: coordinates)
            let boundingBox = calculateBoundingBox(polygons: polygons)

            let boundary = RegionBoundary(
                code: postalCode,
                name: name,
                type: .state,
                continent: .northAmerica,
                boundingBox: boundingBox,
                polygons: polygons
            )
            usStates.append(boundary)
        }
    }

    private func loadUSOutline() {
        guard let url = Bundle.main.url(forResource: "gz_2010_us_outline_5m", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            debugLog("⚠️ Failed to load gz_2010_us_outline_5m.json")
            return
        }

        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any],
                  let geometryType = geometry["type"] as? String,
                  geometryType == "LineString",
                  let coordinates = geometry["coordinates"] as? [[Double]] else {
                continue
            }

            usOutlinePolylines.append(coordinates)
        }
    }

    private func loadCountries() {
        guard let url = Bundle.main.url(forResource: "ne_10m_admin_0_countries", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            debugLog("⚠️ Failed to load ne_10m_admin_0_countries.json")
            return
        }

        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let geometryType = geometry["type"] as? String,
                  let coordinates = geometry["coordinates"] as? [Any] else {
                continue
            }

            // Get country name - try different property names
            let name = (properties["NAME"] as? String) ??
                       (properties["name"] as? String) ??
                       (properties["ADMIN"] as? String) ?? "Unknown"

            // Get country code - try different property names (Natural Earth uses uppercase)
            var code = (properties["ISO_A2"] as? String) ??
                       (properties["iso_a2"] as? String) ??
                       (properties["POSTAL"] as? String)  // Fallback to postal code

            // Check if code is invalid (e.g., "-99" placeholder)
            if code == nil || code == "-99" || code!.hasPrefix("-") {
                // Try to look up the correct code by country name
                code = isoCodeForCountryName(name)
            }

            // Skip if we still don't have a valid code
            guard let finalCode = code, !finalCode.isEmpty, !finalCode.hasPrefix("-") else {
                debugLog("⚠️ Skipping country with no valid ISO code: \(name)")
                continue
            }

            let polygons = extractPolygons(geometryType: geometryType, coordinates: coordinates)
            let boundingBox = calculateBoundingBox(polygons: polygons)

            // Get continent from the file if available, otherwise use our lookup
            let continent: Continent?
            if let continentStr = properties["CONTINENT"] as? String {
                continent = continentFromString(continentStr)
            } else {
                continent = continentForCountry(code: finalCode, name: name)
            }

            let boundary = RegionBoundary(
                code: finalCode,
                name: name,
                type: .country,
                continent: continent,
                boundingBox: boundingBox,
                polygons: polygons
            )
            countries.append(boundary)
        }
    }

    private func loadContinents() {
        guard let url = Bundle.main.url(forResource: "ne_10m_geography_regions_polys", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            debugLog("⚠️ Failed to load ne_10m_geography_regions_polys.json")
            return
        }

        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let featurecla = properties["featurecla"] as? String,
                  featurecla == "Continent",
                  let region = properties["region"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let geometryType = geometry["type"] as? String,
                  let coordinates = geometry["coordinates"] as? [Any] else {
                continue
            }

            guard let continent = continentFromString(region) else {
                debugLog("⚠️ Unknown continent region: \(region)")
                continue
            }

            // Use name with proper case (e.g., "SOUTH AMERICA" -> "South America")
            let rawName = properties["name"] as? String ?? region
            let name = rawName.capitalized
            let polygons = extractPolygons(geometryType: geometryType, coordinates: coordinates)
            let boundingBox = calculateBoundingBox(polygons: polygons)

            let boundary = RegionBoundary(
                code: region,
                name: name,
                type: .country,  // Reusing type, not used for continents
                continent: continent,
                boundingBox: boundingBox,
                polygons: polygons
            )
            continents.append(boundary)
        }
    }

    /// Convert continent string from Natural Earth to our Continent enum
    private func continentFromString(_ str: String) -> Continent? {
        switch str {
        case "Africa": return .africa
        case "Antarctica": return .antarctica
        case "Asia": return .asia
        case "Europe": return .europe
        case "North America": return .northAmerica
        case "South America": return .southAmerica
        case "Oceania": return .oceania
        default: return nil
        }
    }

    /// Lookup table for countries with missing/invalid ISO codes in the GeoJSON
    private func isoCodeForCountryName(_ name: String) -> String? {
        let lookup: [String: String] = [
            "France": "FR",
            "Norway": "NO",
            "Kosovo": "XK",
            "Northern Cyprus": "CY",  // Use Cyprus code
            "Somaliland": "SO",  // Use Somalia code (disputed territory)
            "Indian Ocean Territories": "IO",
            "Coral Sea Islands": "AU",  // Australian territory
            "Clipperton Island": "FR",  // French territory
            "Ashmore and Cartier Islands": "AU",  // Australian territory
            "Spratly Islands": "XX",  // Disputed
            "Southern Patagonian Ice Field": "XX",  // Disputed between Argentina/Chile
            "Siachen Glacier": "XX",  // Disputed
            "Bir Tawil": "XX",  // Unclaimed
            "Baykonur Cosmodrome": "KZ",  // In Kazakhstan
            "Cyprus No Mans Area": "CY",
            "Dhekelia Sovereign Base Area": "GB",  // UK territory
            "Akrotiri Sovereign Base Area": "GB",  // UK territory
            "US Naval Base Guantanamo Bay": "US",
            "Brazilian Island": "BR",
            "Bajo Nuevo Bank (Petrel Is.)": "XX",  // Disputed
            "Serranilla Bank": "XX",  // Disputed
            "Scarborough Reef": "XX",  // Disputed
        ]

        return lookup[name]
    }

    // MARK: - Polygon Extraction

    private func extractPolygons(geometryType: String, coordinates: [Any]) -> [[[Double]]] {
        var polygons: [[[Double]]] = []

        switch geometryType {
        case "Polygon":
            // coordinates is [[lon, lat], [lon, lat], ...]
            if let rings = coordinates as? [[[Double]]] {
                // First ring is exterior, rest are holes (we only use exterior for simplicity)
                if let exteriorRing = rings.first {
                    polygons.append(exteriorRing)
                }
            }

        case "MultiPolygon":
            // coordinates is [polygon, polygon, ...] where each polygon is [[lon, lat], ...]
            if let multiPolygon = coordinates as? [[[[Double]]]] {
                for polygon in multiPolygon {
                    if let exteriorRing = polygon.first {
                        polygons.append(exteriorRing)
                    }
                }
            }

        default:
            debugLog("⚠️ Unknown geometry type: \(geometryType)")
        }

        return polygons
    }

    private func calculateBoundingBox(polygons: [[[Double]]]) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude

        for polygon in polygons {
            for point in polygon {
                guard point.count >= 2 else { continue }
                let lon = point[0]
                let lat = point[1]
                minLat = min(minLat, lat)
                maxLat = max(maxLat, lat)
                minLon = min(minLon, lon)
                maxLon = max(maxLon, lon)
            }
        }

        return (minLat, maxLat, minLon, maxLon)
    }

    private func convertToCoordinates(polygons: [[[Double]]]) -> [[[CLLocationCoordinate2D]]] {
        return polygons.map { polygon in
            [polygon.compactMap { point -> CLLocationCoordinate2D? in
                guard point.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
            }]
        }
    }

    // MARK: - Point-in-Polygon Algorithm

    private func pointInRegion(latitude: Double, longitude: Double, region: RegionBoundary) -> Bool {
        for polygon in region.polygons {
            if pointInPolygon(latitude: latitude, longitude: longitude, polygon: polygon) {
                return true
            }
        }
        return false
    }

    /// Check if a point is within tolerance distance of any polygon edge
    /// Used for coastal/border locations that fall just outside due to polygon simplification
    private func pointNearRegion(latitude: Double, longitude: Double, region: RegionBoundary, tolerance: Double) -> Bool {
        for polygon in region.polygons {
            if pointNearPolygon(latitude: latitude, longitude: longitude, polygon: polygon, tolerance: tolerance) {
                return true
            }
        }
        return false
    }

    /// Check if point is within tolerance of any edge in the polygon
    private func pointNearPolygon(latitude: Double, longitude: Double, polygon: [[Double]], tolerance: Double) -> Bool {
        guard polygon.count >= 3 else { return false }

        var j = polygon.count - 1

        for i in 0..<polygon.count {
            guard polygon[i].count >= 2, polygon[j].count >= 2 else {
                j = i
                continue
            }

            let x1 = polygon[j][0]  // longitude
            let y1 = polygon[j][1]  // latitude
            let x2 = polygon[i][0]
            let y2 = polygon[i][1]

            // Calculate distance from point to line segment
            let distance = distanceToSegment(
                px: longitude, py: latitude,
                x1: x1, y1: y1,
                x2: x2, y2: y2
            )

            if distance <= tolerance {
                return true
            }

            j = i
        }

        return false
    }

    /// Calculate the distance from a point to a line segment
    private func distanceToSegment(px: Double, py: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let dx = x2 - x1
        let dy = y2 - y1

        if dx == 0 && dy == 0 {
            // Segment is a point
            return sqrt((px - x1) * (px - x1) + (py - y1) * (py - y1))
        }

        // Parameter t for closest point on segment
        var t = ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)
        t = max(0, min(1, t))  // Clamp to [0, 1]

        // Closest point on segment
        let closestX = x1 + t * dx
        let closestY = y1 + t * dy

        // Distance to closest point
        return sqrt((px - closestX) * (px - closestX) + (py - closestY) * (py - closestY))
    }

    /// Ray casting algorithm for point-in-polygon test
    private func pointInPolygon(latitude: Double, longitude: Double, polygon: [[Double]]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            guard polygon[i].count >= 2, polygon[j].count >= 2 else {
                j = i
                continue
            }

            let xi = polygon[i][0]  // longitude
            let yi = polygon[i][1]  // latitude
            let xj = polygon[j][0]
            let yj = polygon[j][1]

            // Ray casting: check if horizontal ray from point crosses edge
            if ((yi > latitude) != (yj > latitude)) &&
               (longitude < (xj - xi) * (latitude - yi) / (yj - yi) + xi) {
                inside.toggle()
            }

            j = i
        }

        return inside
    }

    // MARK: - Continent Mapping

    private func continentForCountry(code: String, name: String) -> Continent? {
        // Map countries to continents
        // This is a simplified mapping - covers major countries

        let africaCountries = Set(["DZ", "AO", "BJ", "BW", "BF", "BI", "CV", "CM", "CF", "TD", "KM", "CG", "CD", "CI", "DJ", "EG", "GQ", "ER", "SZ", "ET", "GA", "GM", "GH", "GN", "GW", "KE", "LS", "LR", "LY", "MG", "MW", "ML", "MR", "MU", "MA", "MZ", "NA", "NE", "NG", "RW", "ST", "SN", "SC", "SL", "SO", "ZA", "SS", "SD", "TZ", "TG", "TN", "UG", "ZM", "ZW"])

        let asiaCountries = Set(["AF", "AM", "AZ", "BH", "BD", "BT", "BN", "KH", "CN", "CY", "GE", "IN", "ID", "IR", "IQ", "IL", "JP", "JO", "KZ", "KW", "KG", "LA", "LB", "MY", "MV", "MN", "MM", "NP", "KP", "OM", "PK", "PS", "PH", "QA", "SA", "SG", "KR", "LK", "SY", "TW", "TJ", "TH", "TL", "TR", "TM", "AE", "UZ", "VN", "YE"])

        let europeCountries = Set(["AL", "AD", "AT", "BY", "BE", "BA", "BG", "HR", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IS", "IE", "IT", "XK", "LV", "LI", "LT", "LU", "MT", "MD", "MC", "ME", "NL", "MK", "NO", "PL", "PT", "RO", "RU", "SM", "RS", "SK", "SI", "ES", "SE", "CH", "UA", "GB", "VA"])

        let northAmericaCountries = Set(["AG", "BS", "BB", "BZ", "CA", "CR", "CU", "DM", "DO", "SV", "GD", "GT", "HT", "HN", "JM", "MX", "NI", "PA", "KN", "LC", "VC", "TT", "US"])

        let southAmericaCountries = Set(["AR", "BO", "BR", "CL", "CO", "EC", "GY", "PY", "PE", "SR", "UY", "VE"])

        let oceaniaCountries = Set(["AU", "FJ", "KI", "MH", "FM", "NR", "NZ", "PW", "PG", "WS", "SB", "TO", "TV", "VU"])

        if africaCountries.contains(code) { return .africa }
        if asiaCountries.contains(code) { return .asia }
        if europeCountries.contains(code) { return .europe }
        if northAmericaCountries.contains(code) { return .northAmerica }
        if southAmericaCountries.contains(code) { return .southAmerica }
        if oceaniaCountries.contains(code) { return .oceania }
        if code == "AQ" || name.lowercased().contains("antarctica") { return .antarctica }

        // Default to nil for unrecognized
        return nil
    }
}
