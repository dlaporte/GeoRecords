#!/usr/bin/env python3
"""Build GeoRecords/Resources/continents.json: geographic continent outlines.

The app draws and attributes continents from this file. Each continent is the land
of every polygon part attributed to it, unioned so no country border survives, with
Russia, Kazakhstan and Turkey cut along the Europe/Asia divide (Urals, Ural River,
Caspian, Greater Caucasus crest, Bosporus).

Sources (both bundled in GeoRecords/Resources):
  ne_10m_admin_0_countries.json        Natural Earth 10m countries: the coastlines,
                                       islands and isthmuses, plus each feature's
                                       CONTINENT attribute.
  ne_10m_geography_regions_polys.json  Natural Earth 10m physical regions: only its
                                       Europe/Asia divide and its mainland extents
                                       (camera frames) are used. Its "Continent"
                                       features are mainland leftovers full of holes
                                       and omit islands and Central America, so
                                       they are not drawn.

Part assignment mirrors how the app attributes a visit: a feature's CONTINENT
(with the app's own table for the "Seven seas" island nations), and the app's
overseas-territory boxes for parts embedded in a parent feature (Canaries, Azores,
Madeira, Cocos/Christmas). Only the three divided countries are split.

Output: a FeatureCollection with one Feature per continent, `properties.continent`
equal to the app's Continent raw value, `properties.frame` (simplified physical
mainland rings used to frame the camera) and a MultiPolygon of exterior rings only
(MapKit drops tiles of overlays that carry interior polygons). Six decimals, each
ring rotated to start at its smallest vertex so regeneration keeps the diff small.

Run from the repository root (shapely 2.2.0 was used for the bundled file):
  python3 -m venv .venv && .venv/bin/pip install shapely==2.2.0
  .venv/bin/python tools/build_continents.py
"""
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

from shapely import set_precision
from shapely.geometry import MultiLineString, Point, Polygon, shape
from shapely.ops import linemerge, unary_union

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "GeoRecords" / "Resources"
COUNTRIES_FILE = RESOURCES / "ne_10m_admin_0_countries.json"
PHYSICAL_FILE = RESOURCES / "ne_10m_geography_regions_polys.json"
OUTPUT_FILE = RESOURCES / "continents.json"

# Natural Earth CONTINENT value -> the app's Continent.rawValue
CONTINENTS = {
    "Africa": "Africa",
    "Antarctica": "Antarctica",
    "Asia": "Asia",
    "Europe": "Europe",
    "North America": "North America",
    "Oceania": "Australia / Oceania",
    "South America": "South America",
}

# Port of RegionLookupService.continentForCountry: continent for features the
# countries file labels "Seven seas (open ocean)"
FALLBACK = {}
for _codes, _continent in [
    ("DZ AO BJ BW BF BI CV CM CF TD KM CG CD CI DJ EG GQ ER SZ ET GA GM GH GN GW KE LS LR LY MG MW ML MR MU MA MZ NA NE NG RW ST SN SC SL SO ZA SS SD TZ TG TN UG ZM ZW", "Africa"),
    ("AF AM AZ BH BD BT BN KH CN CY GE IN ID IR IQ IL JP JO KZ KW KG LA LB MY MV MN MM NP KP OM PK PS PH QA SA SG KR LK SY TW TJ TH TL TR TM AE UZ VN YE", "Asia"),
    ("AL AD AT BY BE BA BG HR CZ DK EE FI FR DE GR HU IS IE IT XK LV LI LT LU MT MD MC ME NL MK NO PL PT RO RU SM RS SK SI ES SE CH UA GB VA", "Europe"),
    ("AG BS BB BZ CA CR CU DM DO SV GD GT HT HN JM MX NI PA KN LC VC TT US", "North America"),
    ("AR BO BR CL CO EC GY PY PE SR UY VE", "South America"),
    ("AU FJ KI MH FM NR NZ PW PG WS SB TO TV VU", "Oceania"),
]:
    for _code in _codes.split():
        FALLBACK[_code] = _continent

# Port of RegionLookupService.overseasTerritories: (minLat, maxLat, minLon, maxLon, code, continent).
# Only territories WITHOUT their own feature in the countries file matter here (parts
# embedded in a parent feature); the rest are plain features with their own CONTINENT.
TERRITORIES = [
    (2.0, 6.0, -55.0, -51.0, "GF", "South America"), (14.35, 14.9, -61.3, -60.8, "MQ", "North America"),
    (15.8, 16.55, -61.85, -61.0, "GP", "North America"), (-21.4, -20.85, 55.2, 55.85, "RE", "Africa"),
    (-13.05, -12.6, 45.0, 45.35, "YT", "Africa"), (-22.4, -22.2, 166.3, 166.5, "NC", "Oceania"),
    (-17.9, -17.45, -149.95, -149.1, "PF", "Oceania"), (12.0, 12.65, -68.5, -68.0, "CW", "North America"),
    (12.4, 12.65, -70.1, -69.85, "AW", "North America"), (17.45, 18.07, -63.15, -62.95, "SX", "North America"),
    (32.25, 32.4, -64.9, -64.65, "BM", "North America"), (18.15, 19.4, -64.85, -64.25, "VG", "North America"),
    (19.25, 19.4, -81.45, -81.05, "KY", "North America"), (-54.9, -51.0, -61.5, -57.5, "FK", "South America"),
    (-4.75, -4.65, 55.45, 55.55, "SC", "Africa"), (36.1, 36.16, -5.37, -5.33, "GI", "Europe"),
    (36.9, 39.75, -31.3, -25.0, "PT-20", "Europe"), (32.6, 33.15, -17.3, -16.25, "PT-30", "Europe"),
    (27.6, 29.5, -18.2, -13.3, "ES-CN", "Europe"), (61.35, 62.45, -7.7, -6.2, "FO", "Europe"),
    (59.5, 83.7, -73.0, -11.0, "GL", "North America"), (-10.7, -10.35, 105.5, 105.75, "CX", "Oceania"),
    (-12.25, -11.8, 96.8, 96.95, "CC", "Oceania"), (-29.15, -29.0, 167.9, 168.0, "NF", "Oceania"),
    (-21.3, -21.15, -159.85, -159.7, "CK", "Oceania"), (-19.15, -18.95, -169.95, -169.75, "NU", "Oceania"),
    (-9.25, -8.5, -172.0, -171.0, "TK", "Oceania"),
]

# Countries cut along the Europe/Asia divide
DIVIDED = {"RU", "KZ", "TR"}

# Places that must land inside (or within COAST_TOLERANCE of) the expected continent.
# (lon, lat, Natural Earth continent name)
SAMPLES = {
    "Moscow": (37.62, 55.75, "Europe"), "Perm": (56.23, 58.0, "Europe"), "Orenburg": (55.1, 51.77, "Europe"),
    "Grozny": (45.69, 43.32, "Europe"), "Novaya Zemlya": (56.0, 73.5, "Europe"), "Uralsk": (51.23, 51.37, "Europe"),
    "Istanbul (European side)": (28.95, 41.03, "Europe"), "Edirne": (26.56, 41.68, "Europe"),
    "Yekaterinburg": (60.6, 56.84, "Asia"), "Salekhard": (66.53, 66.6, "Asia"), "Novosibirsk": (82.9, 55.0, "Asia"),
    "Khabarovsk": (135.07, 48.48, "Asia"), "Vladivostok": (131.9, 43.1, "Asia"), "Sochi": (39.72, 43.6, "Asia"),
    "Almaty": (76.9, 43.2, "Asia"), "Aktau": (51.2, 43.65, "Asia"), "Ankara": (32.85, 39.93, "Asia"),
    "Istanbul (Asian side)": (29.05, 41.0, "Asia"), "Izmir": (27.14, 38.42, "Asia"),
    "Baku": (49.87, 40.41, "Asia"), "Tbilisi": (44.8, 41.7, "Asia"), "Nicosia": (33.36, 35.17, "Asia"),
    "Jakarta": (106.8, -6.2, "Asia"), "Manila": (121.0, 14.6, "Asia"), "Tokyo": (139.7, 35.7, "Asia"),
    "Male": (73.5, 4.17, "Asia"), "Colombo": (79.86, 6.93, "Asia"),
    "London": (-0.12, 51.5, "Europe"), "Reykjavik": (-21.9, 64.13, "Europe"), "Dublin": (-6.26, 53.35, "Europe"),
    "Las Palmas": (-15.43, 28.12, "Europe"), "Ponta Delgada": (-25.67, 37.74, "Europe"), "Gibraltar": (-5.35, 36.14, "Europe"),
    "Torshavn": (-6.77, 62.01, "Europe"), "Rhodes": (28.2, 36.4, "Europe"),
    "Cairo": (31.24, 30.04, "Africa"), "Sharm el-Sheikh": (34.33, 27.91, "Africa"), "Antananarivo": (47.5, -18.9, "Africa"),
    "Saint-Denis (Reunion)": (55.45, -20.88, "Africa"), "Victoria (Seychelles)": (55.45, -4.62, "Africa"), "Port Louis": (57.5, -20.16, "Africa"),
    "Lagos": (3.4, 6.45, "Africa"), "Cape Town": (18.42, -33.93, "Africa"),
    "Panama City": (-79.52, 8.98, "North America"), "San Jose (Costa Rica)": (-84.08, 9.93, "North America"),
    "Guatemala City": (-90.51, 14.63, "North America"), "Cancun": (-86.85, 21.16, "North America"),
    "Havana": (-82.38, 23.13, "North America"), "Nassau": (-77.34, 25.08, "North America"),
    "Port of Spain": (-61.52, 10.65, "North America"), "Fort-de-France": (-61.07, 14.6, "North America"),
    "Nuuk": (-51.72, 64.18, "North America"), "Honolulu": (-157.86, 21.3, "North America"),
    "Bermuda": (-64.78, 32.3, "North America"), "Mexico City": (-99.13, 19.43, "North America"),
    "Denver": (-104.99, 39.74, "North America"), "Anchorage": (-149.9, 61.22, "North America"),
    "Bogota": (-74.07, 4.71, "South America"), "Cayenne": (-52.33, 4.93, "South America"),
    "Stanley (Falklands)": (-57.85, -51.69, "South America"), "Ushuaia": (-68.3, -54.8, "South America"), "Lima": (-77.03, -12.05, "South America"),
    "Sydney": (151.2, -33.9, "Oceania"), "Auckland": (174.76, -36.85, "Oceania"), "Port Moresby": (147.18, -9.44, "Oceania"),
    "Noumea": (166.45, -22.27, "Oceania"), "Papeete": (-149.57, -17.54, "Oceania"), "Suva": (178.44, -18.14, "Oceania"),
    "Hobart": (147.33, -42.88, "Oceania"), "McMurdo": (166.67, -77.85, "Antarctica"),
}
COAST_TOLERANCE = 0.01  # degrees, matches the app's coastal lookup tolerance


def feature_code(properties):
    code = properties.get("ISO_A2")
    if code in (None, "-99", "-1"):
        code = properties.get("ISO_A2_EH")
    return code


def feature_continent(properties, code):
    continent = properties.get("CONTINENT")
    if continent in CONTINENTS:
        return continent
    return FALLBACK.get(code)


def line_parts(geom):
    if geom.geom_type == "LineString":
        return [geom]
    if geom.geom_type in ("MultiLineString", "GeometryCollection"):
        return [line for sub in geom.geoms for line in line_parts(sub)]
    return []


def europe_side_polygon(physical):
    """Everything west of the Europe/Asia divide, as one big polygon.

    The divide is the part of the physical Europe polygon's boundary that runs along
    the physical Asia polygon, chained north to south. An Arctic gate between Novaya
    Zemlya and Yamal and a tail into the Mediterranean close it off.
    """
    europe, asia = physical["EUROPE"], physical["ASIA"]
    shared = europe.boundary.intersection(asia.buffer(0.1))
    pieces = [p for p in line_parts(linemerge(MultiLineString(line_parts(shared)))) if p.length > 0.5]
    pieces.sort(key=lambda line: -max(c[1] for c in line.coords))
    chain = []
    for line in pieces:
        coords = list(line.coords)
        if coords[0][1] < coords[-1][1]:
            coords.reverse()
        chain.extend(coords)
    north, south = chain[0], chain[-1]
    assert north[1] > 68 and 64 < north[0] < 68, f"divide north end drifted: {north}"
    assert south[1] < 37 and 27 < south[0] < 30, f"divide south end drifted: {south}"
    arctic_gate = [(72.0, 90.0), (72.0, 77.5), (66.0, 73.5), (65.0, 70.0)]
    mediterranean_tail = [(27.0, 34.0), (-30.0, 34.0), (-30.0, 90.0), (72.0, 90.0)]
    return Polygon(arctic_gate + chain + mediterranean_tail).buffer(0)


def assign_parts(countries, europe_side):
    """Polygon parts per Natural Earth continent name."""
    own_codes = {feature_code(f["properties"]) for f in countries["features"]}
    embedded_territories = [t for t in TERRITORIES if t[4] not in own_codes]
    parts = defaultdict(list)
    for feature in countries["features"]:
        properties = feature["properties"]
        code = feature_code(properties)
        continent = feature_continent(properties, code)
        geometry = set_precision(shape(feature["geometry"]), 1e-7)
        polygons = list(geometry.geoms) if geometry.geom_type == "MultiPolygon" else [geometry]
        own_territory = next((t for t in TERRITORIES if t[4] == code), None)
        for polygon in polygons:
            if polygon.is_empty:
                continue
            target = own_territory[5] if own_territory else None
            if target is None:
                point = polygon.representative_point()
                for min_lat, max_lat, min_lon, max_lon, _code, territory_continent in embedded_territories:
                    if min_lat <= point.y <= max_lat and min_lon <= point.x <= max_lon:
                        target = territory_continent
                        break
            if target is None:
                target = continent
            if target is None:
                continue
            if code in DIVIDED:
                for side, piece in (("Europe", polygon.intersection(europe_side)), ("Asia", polygon.difference(europe_side))):
                    for sub in (piece.geoms if piece.geom_type == "MultiPolygon" else [piece]):
                        if sub.geom_type == "Polygon" and sub.area > 0:
                            parts[side].append(sub)
            else:
                parts[target].append(polygon)
    return parts


def ring_coordinates(ring, decimals):
    """Closed ring as rounded [lon, lat] pairs, rotated to start at its smallest vertex."""
    coords = [(round(x, decimals), round(y, decimals)) for x, y in ring.coords]
    if coords and coords[0] == coords[-1]:
        coords.pop()
    deduped = [c for i, c in enumerate(coords) if i == 0 or c != coords[i - 1]]
    start = deduped.index(min(deduped))
    rotated = deduped[start:] + deduped[:start]
    rotated.append(rotated[0])
    return [[x, y] for x, y in rotated]


def build():
    started = time.time()
    countries = json.load(open(COUNTRIES_FILE))
    physical_file = json.load(open(PHYSICAL_FILE))
    physical = {f["properties"]["name"]: shape(f["geometry"])
                for f in physical_file["features"] if f["properties"]["featurecla"] == "Continent"}
    physical_by_continent = {"Africa": "AFRICA", "Antarctica": "ANTARCTICA", "Asia": "ASIA", "Europe": "EUROPE",
                             "North America": "NORTH AMERICA", "Oceania": "AUSTRALIA", "South America": "SOUTH AMERICA"}

    europe_side = europe_side_polygon(physical)
    parts = assign_parts(countries, europe_side)

    features = []
    built = {}
    for continent, raw_value in CONTINENTS.items():
        union = unary_union(parts[continent])
        polygons = list(union.geoms) if union.geom_type == "MultiPolygon" else [union]
        exteriors = sorted((Polygon(p.exterior) for p in polygons if p.area > 0), key=lambda p: -p.area)
        assert exteriors, f"{continent} has no polygons"
        built[continent] = unary_union(exteriors)
        frame = [ring_coordinates(part.exterior.simplify(0.2, preserve_topology=True), 4)
                 for part in getattr(physical[physical_by_continent[continent]], "geoms", [physical[physical_by_continent[continent]]])]
        features.append({
            "type": "Feature",
            "properties": {"continent": raw_value, "frame": frame},
            "geometry": {"type": "MultiPolygon", "coordinates": [[ring_coordinates(p.exterior, 6)] for p in exteriors]},
        })
        holes = sum(len(p.interiors) for p in polygons)
        vertices = sum(len(p.exterior.coords) for p in exteriors)
        print(f"{continent:14s} {len(exteriors):5d} polygons {vertices:7d} vertices {holes:3d} holes dropped")

    failures = []
    for name, (lon, lat, expected) in SAMPLES.items():
        point = Point(lon, lat)
        hits = [c for c, g in built.items() if g.contains(point)]
        if hits != [expected] and not (not hits and built[expected].distance(point) <= COAST_TOLERANCE):
            failures.append(f"{name}: expected {expected}, got {hits or 'nothing within tolerance'}")
    assert not failures, "sample places off their continent:\n  " + "\n  ".join(failures)

    with open(OUTPUT_FILE, "w") as out:
        json.dump({"type": "FeatureCollection", "features": features}, out, separators=(",", ":"))
    print(f"wrote {OUTPUT_FILE.relative_to(ROOT)} ({os.path.getsize(OUTPUT_FILE) // 1024} KB) in {time.time() - started:.1f}s; "
          f"{len(SAMPLES)} sample places verified")


if __name__ == "__main__":
    sys.exit(build())
