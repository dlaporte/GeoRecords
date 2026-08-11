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

    /// Ensure boundary data is loaded (idempotent; safe to call from any thread).
    ///
    /// Every public accessor calls this unconditionally: the serial queue both
    /// prevents a double load and gives the calling thread a memory barrier, so the
    /// boundary arrays it reads afterwards are fully visible. (A bare `isLoaded`
    /// fast-path outside the queue was a data race.) The ~36MB GeoJSON parse happens
    /// on whichever thread first gets here — GeoRecords.swift warms it from a
    /// background task at startup so first Maps view / photo scan doesn't pay it
    /// on the main thread.
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
        loadBoundaries()

        let lat = coordinate.latitude
        let lon = coordinate.longitude

        // First check overseas territories (before parent countries claim them)
        // These territories are part of parent country MultiPolygons in the GeoJSON,
        // but should be tracked as separate regions
        if let overseasTerritory = checkOverseasTerritories(latitude: lat, longitude: lon) {
            return overseasTerritory
        }

        // Then check US states (more specific)
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

    /// Map territory codes to possible GeoJSON names (for polygon lookup)
    /// Some territories have different names in GeoJSON data - try multiple variations
    private static let territoryToGeoJSONNames: [String: [String]] = [
        "PT-20": ["açores", "azores", "acores"],
        "PT-30": ["madeira"],
        "ES-CN": ["canarias", "canary islands", "islas canarias"],
    ]

    /// Get all polygon coordinates for a region (for map overlays)
    /// - Parameter regionCode: The region code (e.g., "US-CA", "FR")
    /// - Returns: Array of polygon coordinate arrays
    func polygons(for regionCode: String) -> [[[CLLocationCoordinate2D]]] {
        loadBoundaries()

        // Check if it's a US state (with "US-" prefix)
        if regionCode.hasPrefix("US-") {
            let stateCode = String(regionCode.dropFirst(3))
            if let state = usStates.first(where: { $0.code == stateCode }) {
                return convertToCoordinates(polygons: state.polygons)
            }
        }

        // Check countries by code BEFORE bare 2-letter state codes
        // This prevents collisions like "CA" (Canada) vs "CA" (California)
        if let country = countries.first(where: { $0.code == regionCode }) {
            return convertToCoordinates(polygons: country.polygons)
        }

        // Check if it's a bare 2-letter US state code (without "US-" prefix)
        // This handles legacy data that may not have the prefix
        // Done AFTER country check to avoid code collisions (e.g., CA, CO, etc.)
        if regionCode.count == 2 {
            if let state = usStates.first(where: { $0.code == regionCode }) {
                return convertToCoordinates(polygons: state.polygons)
            }
        }

        // Check if it's a territory with mapped GeoJSON names
        if let geoJSONNames = Self.territoryToGeoJSONNames[regionCode] {
            for geoJSONName in geoJSONNames {
                if let country = countries.first(where: { $0.name.lowercased() == geoJSONName }) {
                    debugLog("📍 Found polygon for territory '\(regionCode)' using name '\(country.name)'")
                    return convertToCoordinates(polygons: country.polygons)
                }
            }
        }

        // For territories, try to extract polygons from parent country that fall within the territory's bounding box
        if let parentCode = territoryToParentCountry[regionCode],
           let parentCountry = countries.first(where: { $0.code == parentCode }) {
            // Get the territory's bounding box from our definitions
            if let territoryBounds = getTerritoryBoundingBox(regionCode) {
                let filteredPolygons = parentCountry.polygons.filter { polygon in
                    // Check if any point of this polygon falls within the territory's bounding box
                    for point in polygon {
                        guard point.count >= 2 else { continue }
                        let lon = point[0]
                        let lat = point[1]
                        if lat >= territoryBounds.minLat && lat <= territoryBounds.maxLat &&
                           lon >= territoryBounds.minLon && lon <= territoryBounds.maxLon {
                            return true
                        }
                    }
                    return false
                }
                if !filteredPolygons.isEmpty {
                    debugLog("📍 Extracted \(filteredPolygons.count) polygons for territory '\(regionCode)' from parent '\(parentCode)'")
                    return convertToCoordinates(polygons: filteredPolygons)
                }
            }
        }

        return []
    }

    /// Get bounding box for a territory (used for extracting polygons from parent country)
    private func getTerritoryBoundingBox(_ code: String) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        // Territory bounding boxes (same as in checkOverseasTerritories)
        let territoryBounds: [String: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)] = [
            "PT-20": (36.9, 39.75, -31.3, -25.0),    // Azores
            "PT-30": (32.6, 33.15, -17.3, -16.25),   // Madeira
            "ES-CN": (27.6, 29.5, -18.2, -13.3),    // Canary Islands
            "GF": (2.0, 6.0, -55.0, -51.0),          // French Guiana
            "MQ": (14.35, 14.9, -61.3, -60.8),       // Martinique
            "GP": (15.8, 16.55, -61.85, -61.0),      // Guadeloupe
            "RE": (-21.4, -20.85, 55.2, 55.85),      // Réunion
            "YT": (-13.05, -12.6, 45.0, 45.35),      // Mayotte
            "NC": (-22.4, -22.2, 166.3, 166.5),      // New Caledonia
            "PF": (-17.9, -17.45, -149.95, -149.1),  // French Polynesia
            "GL": (59.5, 83.7, -73.0, -11.0),        // Greenland
            "FO": (61.35, 62.45, -7.7, -6.2),        // Faroe Islands
        ]
        return territoryBounds[code]
    }

    /// Get all loaded US states
    var allUSStates: [RegionInfo] {
        loadBoundaries()
        return usStates.map { RegionInfo(code: "US-\($0.code)", name: $0.name, type: .state, continent: .northAmerica) }
    }

    /// Get all loaded countries
    var allCountries: [RegionInfo] {
        loadBoundaries()
        return countries.map { RegionInfo(code: $0.code, name: $0.name, type: .country, continent: $0.continent) }
    }

    /// Get polygon coordinates for a continent (for map overlays)
    /// - Parameter continent: The continent enum value
    /// - Returns: Array of polygon coordinate arrays
    func continentPolygons(for continent: Continent) -> [[[CLLocationCoordinate2D]]] {
        loadBoundaries()

        if let continentBoundary = continents.first(where: { $0.continent == continent }) {
            return convertToCoordinates(polygons: continentBoundary.polygons)
        }

        return []
    }

    /// Get US outline polylines (for map overlays)
    /// - Returns: Array of polyline coordinate arrays
    func getUSOutlinePolylines() -> [[CLLocationCoordinate2D]] {
        loadBoundaries()

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

        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let name = properties["NAME"] as? String,
                  let fipsCode = properties["STATE"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let geometryType = geometry["type"] as? String,
                  let coordinates = geometry["coordinates"] as? [Any] else {
                continue
            }

            // Convert FIPS to postal code (uses centralized mapping from Constants)
            guard let postalCode = fipsToPostalCode[fipsCode] else {
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

    // MARK: - Overseas Territories Detection
    // Note: Territory mappings (territoryToParentCountry, territoryCodes, isTerritory, flagCodeForRegion)
    // are defined in Constants.swift for use across the app

    /// Check if coordinates fall within known overseas territories
    /// These are geographically separate from their parent countries but share the same
    /// country code in the GeoJSON data. We detect them by bounding box to give them
    /// distinct region codes.
    /// Note: US territories are NOT included here - they are tracked as states instead.
    private func checkOverseasTerritories(latitude lat: Double, longitude lon: Double) -> RegionInfo? {
        // Define overseas territories with their bounding boxes and info
        // Format: (minLat, maxLat, minLon, maxLon, code, name, continent)
        let territories: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
                          code: String, name: String, continent: Continent)] = [
            // French Overseas Territories
            (2.0, 6.0, -55.0, -51.0, "GF", "French Guiana", .southAmerica),
            (14.35, 14.9, -61.3, -60.8, "MQ", "Martinique", .northAmerica),
            (15.8, 16.55, -61.85, -61.0, "GP", "Guadeloupe", .northAmerica),
            (-21.4, -20.85, 55.2, 55.85, "RE", "Réunion", .africa),
            (-13.05, -12.6, 45.0, 45.35, "YT", "Mayotte", .africa),
            (-22.4, -22.2, 166.3, 166.5, "NC", "New Caledonia", .oceania),  // Main island area
            (-17.9, -17.45, -149.95, -149.1, "PF", "French Polynesia", .oceania),  // Tahiti area

            // Dutch Overseas Territories
            (12.0, 12.65, -68.5, -68.0, "CW", "Curaçao", .northAmerica),
            (12.4, 12.65, -70.1, -69.85, "AW", "Aruba", .northAmerica),
            (17.45, 18.07, -63.15, -62.95, "SX", "Sint Maarten", .northAmerica),

            // British Overseas Territories
            (32.25, 32.4, -64.9, -64.65, "BM", "Bermuda", .northAmerica),
            (18.15, 19.4, -64.85, -64.25, "VG", "British Virgin Islands", .northAmerica),
            (19.25, 19.4, -81.45, -81.05, "KY", "Cayman Islands", .northAmerica),
            (-54.9, -51.0, -61.5, -57.5, "FK", "Falkland Islands", .southAmerica),
            (-4.75, -4.65, 55.45, 55.55, "SC", "Seychelles", .africa),  // Main island area
            (36.1, 36.16, -5.37, -5.33, "GI", "Gibraltar", .europe),

            // Portuguese Overseas Territories
            (36.9, 39.75, -31.3, -25.0, "PT-20", "Azores", .europe),  // Use PT-20 to distinguish
            (32.6, 33.15, -17.3, -16.25, "PT-30", "Madeira", .europe),  // Use PT-30 to distinguish

            // Spanish Overseas Territories
            (27.6, 29.5, -18.2, -13.3, "ES-CN", "Canary Islands", .europe),  // Use ES-CN to distinguish

            // Danish Overseas Territories
            (61.35, 62.45, -7.7, -6.2, "FO", "Faroe Islands", .europe),
            (59.5, 83.7, -73.0, -11.0, "GL", "Greenland", .northAmerica),

            // Note: US territories (PR, VI, GU, AS, MP) are tracked as states, not countries

            // Australian Overseas Territories
            (-10.7, -10.35, 105.5, 105.75, "CX", "Christmas Island", .oceania),
            (-12.25, -11.8, 96.8, 96.95, "CC", "Cocos (Keeling) Islands", .oceania),
            (-29.15, -29.0, 167.9, 168.0, "NF", "Norfolk Island", .oceania),

            // New Zealand Overseas Territories
            (-21.3, -21.15, -159.85, -159.7, "CK", "Cook Islands", .oceania),  // Rarotonga area
            (-19.15, -18.95, -169.95, -169.75, "NU", "Niue", .oceania),
            (-9.25, -8.5, -172.0, -171.0, "TK", "Tokelau", .oceania),
        ]

        for territory in territories {
            if lat >= territory.minLat && lat <= territory.maxLat &&
               lon >= territory.minLon && lon <= territory.maxLon {
                // A bounding box alone is too coarse for the larger territories:
                // Greenland's box contains ALL of Iceland and much of northeastern
                // Canada, so box-only matching attributed Iceland photos to Greenland.
                // When real polygons are resolvable for the territory, require an
                // actual polygon hit — with the same coastal tolerance the main country
                // path uses, so a shoreline photo in the Azores doesn't fall through to
                // mainland Portugal. Box-only matching remains only for territories
                // with no usable polygons (small islands whose boxes are all ocean).
                let polygons = rawTerritoryPolygons(for: territory.code)
                if !polygons.isEmpty {
                    let coastalTolerance = 0.01  // ~1.1km, matches the country lookup
                    let inside = polygons.contains {
                        pointInPolygon(latitude: lat, longitude: lon, polygon: $0) ||
                        pointNearPolygon(latitude: lat, longitude: lon, polygon: $0, tolerance: coastalTolerance)
                    }
                    guard inside else { continue }
                }
                return RegionInfo(
                    code: territory.code,
                    name: territory.name,
                    type: .country,
                    continent: territory.continent
                )
            }
        }

        return nil
    }

    /// Raw polygons for a territory code, resolved the same way polygons(for:) does:
    /// the territory's own GeoJSON feature if present (by code, then by mapped name),
    /// else the parent country's polygon parts inside the territory's bounding box.
    /// Empty when nothing is resolvable.
    private func rawTerritoryPolygons(for code: String) -> [[[Double]]] {
        if let own = countries.first(where: { $0.code == code }) {
            return own.polygons
        }

        if let geoJSONNames = Self.territoryToGeoJSONNames[code] {
            for geoJSONName in geoJSONNames {
                if let country = countries.first(where: { $0.name.lowercased() == geoJSONName }) {
                    return country.polygons
                }
            }
        }

        if let parentCode = territoryToParentCountry[code],
           let parentCountry = countries.first(where: { $0.code == parentCode }),
           let bounds = getTerritoryBoundingBox(code) {
            return parentCountry.polygons.filter { polygon in
                polygon.contains { point in
                    point.count >= 2 &&
                    point[1] >= bounds.minLat && point[1] <= bounds.maxLat &&
                    point[0] >= bounds.minLon && point[0] <= bounds.maxLon
                }
            }
        }

        return []
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

    // MARK: - Name to Code Lookups (for migration)

    /// Look up state code by full name (e.g., "Colorado" -> "CO")
    func stateCodeForName(_ name: String) -> String? {
        loadBoundaries()

        // Search through US states
        for boundary in usStates {
            if boundary.name.lowercased() == name.lowercased() {
                return boundary.code
            }
        }
        return nil
    }

    /// Look up country ISO code by full name (e.g., "Poland" -> "PL")
    func countryCodeForName(_ name: String) -> String? {
        loadBoundaries()

        // Search through countries
        for boundary in countries {
            if boundary.name.lowercased() == name.lowercased() {
                return boundary.code
            }
        }
        return nil
    }

    /// Look up country or territory code by name
    /// First checks territories (e.g., "Azores" -> "PT-20"), then falls back to countries
    func countryOrTerritoryCodeForName(_ name: String) -> String? {
        // First check territory names
        if let territoryCode = territoryCodeForName(name) {
            return territoryCode
        }

        // Fall back to country lookup
        return countryCodeForName(name)
    }

    /// Look up territory code by name (e.g., "Azores" -> "PT-20")
    /// Uses the same territory definitions as checkOverseasTerritories
    func territoryCodeForName(_ name: String) -> String? {
        // Territory name to code mapping
        let territoryNameToCode: [String: String] = [
            // Portuguese territories
            "azores": "PT-20",
            "açores": "PT-20",
            "madeira": "PT-30",

            // Spanish territories
            "canary islands": "ES-CN",
            "canarias": "ES-CN",
            "islas canarias": "ES-CN",

            // French territories
            "french guiana": "GF",
            "martinique": "MQ",
            "guadeloupe": "GP",
            "réunion": "RE",
            "reunion": "RE",
            "mayotte": "YT",
            "new caledonia": "NC",
            "french polynesia": "PF",

            // Dutch territories
            "curaçao": "CW",
            "curacao": "CW",
            "aruba": "AW",
            "sint maarten": "SX",

            // British territories
            "bermuda": "BM",
            "british virgin islands": "VG",
            "cayman islands": "KY",
            "falkland islands": "FK",
            "seychelles": "SC",
            "gibraltar": "GI",

            // Danish territories
            "faroe islands": "FO",
            "greenland": "GL",

            // Australian territories
            "christmas island": "CX",
            "cocos (keeling) islands": "CC",
            "cocos islands": "CC",
            "norfolk island": "NF",

            // New Zealand territories
            "cook islands": "CK",
            "niue": "NU",
            "tokelau": "TK",
        ]

        return territoryNameToCode[name.lowercased()]
    }
}
