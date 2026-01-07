# GeoRecords Refactoring Plan
## Critical & High Priority Items (Session 2)

**Status**: Items #1-2 completed in Session 1. This document covers items #3-10.

**Total Estimated Time**: 12-16 hours

---

## ✅ COMPLETED (Session 1)

### Item #1: CardSizing Struct ✓
- **Status**: COMPLETE
- **Location**: Extracted to `/Users/dlaporte/code/GeoRecords/GeoRecords/SharedComponents.swift`
- **Removed From**:
  - RecordsView.swift (lines 331-348)
  - MapsTabView.swift (lines 177-192)

### Item #2: RecordPhotoThumbnail ✓ (Partial)
- **Status**: EXTRACTED but needs usage update
- **Location**: Added to `SharedComponents.swift` (lines 37-96)
- **Removed From**: RecordsView.swift (lines 386-445)
- **TODO**: Update MapsTabView.swift to use shared component instead of `VisitedRegionPhotoThumbnail`
  - Find all usages of `VisitedRegionPhotoThumbnail` and replace with `RecordPhotoThumbnail`
  - Delete the duplicate struct from MapsTabView.swift

---

## 🔴 CRITICAL PRIORITY (Items #3-5)

### Item #3: Extract RecordCardHeader Component
**Estimated Time**: 30 minutes

**Issue**: RecordCardHeader component (RecordsView.swift lines 333-378) is used only in RecordsView but could be reusable.

**Current Location**: RecordsView.swift, lines 333-378
```swift
private struct RecordCardHeader: View {
    let recordType: String
    let timestamp: Date
    let sizing: CardSizing

    var body: some View {
        HStack(alignment: .center, spacing: sizing.cardSpacing) {
            // Icon + Record Type + Date
        }
    }
}
```

**Action Plan**:
1. Move `RecordCardHeader` to `SharedComponents.swift`
2. Make it public (remove `private`)
3. Keep all parameters and logic unchanged
4. Test in RecordsView to ensure it still works

**Verification**: Build succeeds, RecordsView cards display correctly

---

### Item #4: Create Shared Polygon Bounds Calculation Utility
**Estimated Time**: 1 hour

**Issue**: Identical polygon bounds logic appears 3 times:
- StatesMapView.mapRegion (MapsTabView.swift lines 285-319)
- CountriesMapView.mapRegion (lines 410-444)
- ContinentsMapView.mapRegion (lines 535-570)

**Current Code Pattern** (repeated 3x):
```swift
private var mapRegion: MKCoordinateRegion {
    let polygons = /* get polygons */

    guard !polygons.isEmpty else {
        return MKCoordinateRegion(/* default */)
    }

    var minLat = Double.infinity
    var maxLat = -Double.infinity
    var minLon = Double.infinity
    var maxLon = -Double.infinity

    for polygon in polygons {
        for ring in polygon {
            for coord in ring {
                minLat = min(minLat, coord.latitude)
                maxLat = max(maxLat, coord.latitude)
                minLon = min(minLon, coord.longitude)
                maxLon = max(maxLon, coord.longitude)
            }
        }
    }

    let center = CLLocationCoordinate2D(
        latitude: (minLat + maxLat) / 2,
        longitude: (minLon + maxLon) / 2
    )

    let spanLat = max((maxLat - minLat) * 1.5, 0.5)
    let spanLon = max((maxLon - minLon) * 1.5, 0.5)

    // Validate spans
    let validSpanLat = min(max(spanLat, 0.5), 180.0)
    let validSpanLon = min(max(spanLon, 0.5), 360.0)

    return MKCoordinateRegion(
        center: center,
        span: MKCoordinateSpan(latitudeDelta: validSpanLat, longitudeDelta: validSpanLon)
    )
}
```

**Action Plan**:
1. Create new file: `/Users/dlaporte/code/GeoRecords/GeoRecords/MapUtilities.swift`
2. Add function:
```swift
import MapKit
import CoreLocation

/// Calculates a map region that encompasses all given polygons with padding
/// - Parameters:
///   - polygons: Array of polygon rings (each ring is an array of coordinates)
///   - padding: Multiplier for span (default 1.5 adds 50% padding)
///   - defaultRegion: Fallback region if polygons are empty
/// - Returns: MKCoordinateRegion that fits all polygons
func calculateMapRegion(
    for polygons: [[[CLLocationCoordinate2D]]],
    padding: Double = 1.5,
    defaultRegion: MKCoordinateRegion
) -> MKCoordinateRegion {
    guard !polygons.isEmpty else {
        return defaultRegion
    }

    var minLat = Double.infinity
    var maxLat = -Double.infinity
    var minLon = Double.infinity
    var maxLon = -Double.infinity

    for polygon in polygons {
        for ring in polygon {
            for coord in ring {
                minLat = min(minLat, coord.latitude)
                maxLat = max(maxLat, coord.latitude)
                minLon = min(minLon, coord.longitude)
                maxLon = max(maxLon, coord.longitude)
            }
        }
    }

    let center = CLLocationCoordinate2D(
        latitude: (minLat + maxLat) / 2,
        longitude: (minLon + maxLon) / 2
    )

    let spanLat = max((maxLat - minLat) * padding, 0.5)
    let spanLon = max((maxLon - minLon) * padding, 0.5)

    // Validate spans to prevent invalid regions
    let validSpanLat = min(max(spanLat, 0.5), 180.0)
    let validSpanLon = min(max(spanLon, 0.5), 360.0)

    return MKCoordinateRegion(
        center: center,
        span: MKCoordinateSpan(latitudeDelta: validSpanLat, longitudeDelta: validSpanLon)
    )
}
```

3. Update MapsTabView.swift three times:
   - Replace StatesMapView.mapRegion calculation (lines 285-319)
   - Replace CountriesMapView.mapRegion calculation (lines 410-444)
   - Replace ContinentsMapView.mapRegion calculation (lines 535-570)

4. Usage example:
```swift
private var mapRegion: MKCoordinateRegion {
    calculateMapRegion(
        for: regionManager.statePolygons,
        defaultRegion: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.8, longitude: -98.6),
            span: MKCoordinateSpan(latitudeDelta: 50, longitudeDelta: 50)
        )
    )
}
```

**Lines to Delete**: ~105 lines total (35 lines × 3 occurrences)

**Verification**:
- Navigate to each region tab (States/Countries/Continents)
- Verify map centers and zooms correctly on visited regions
- Verify empty states still work

---

### Item #5: Create Generic EmptyRegionStateView Component
**Estimated Time**: 30 minutes

**Issue**: Empty state view duplicated 3x in MapsTabView.swift:
- StatesMapView (lines 350-363)
- CountriesMapView (lines 475-488)
- ContinentsMapView (lines 604-617)

**Current Pattern**:
```swift
VStack(spacing: 12) {
    Image(systemName: "map")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
    Text("No states visited yet")
        .font(.headline)
    Text("Visit a new state and import photos to see it here.")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
}
```

**Action Plan**:
1. Add to `SharedComponents.swift`:
```swift
// MARK: - Empty Region State View

/// Generic empty state view for region tabs
struct EmptyRegionStateView: View {
    let regionType: RegionType

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No \(regionType.pluralName.lowercased()) visited yet")
                .font(.headline)

            Text("Visit a new \(regionType.singularName.lowercased()) and import photos to see it here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var iconName: String {
        switch regionType {
        case .state: return "map"
        case .country: return "globe.americas"
        case .continent: return "globe"
        default: return "map"
        }
    }
}
```

2. Update MapsTabView.swift three places:
   - Replace StatesMapView empty state (lines 350-363)
   - Replace CountriesMapView empty state (lines 475-488)
   - Replace ContinentsMapView empty state (lines 604-617)

3. Usage:
```swift
EmptyRegionStateView(regionType: .state)
```

**Lines to Delete**: ~45 lines total (15 lines × 3)

**Verification**: Test each region tab with no visited regions

---

## 🟡 HIGH PRIORITY (Items #6-10)

### Item #6: Refactor Statistics Chart Data Generation
**Estimated Time**: 4-5 hours
**IMPACT**: Eliminates ~300 lines of duplication

**Issue**: Four methods in StatisticsView.swift contain nearly identical switch statements:
- `chartDataForNS` (lines 479-559): 80 lines
- `chartDataForEW` (lines 561-641): 80 lines
- `chartDataForElevation` (lines 643-714): 70 lines
- `chartDataForDistance` (lines 716-787): 70 lines

**Pattern**:
```swift
private var chartDataForNS: [BidirectionalChartDataPoint] {
    switch selectedTimeFrame {
    case .month:
        // Month logic - extract from dailyRecordsCache
    case .year:
        // Year logic - extract from monthlyAggregates
    case .allTime:
        // All time logic - extract from yearlyAggregates
    case .daily:
        return []
    }
}
```

**Action Plan**:

1. Create generic chart data generator in StatisticsView.swift:

```swift
// MARK: - Generic Chart Data Generation

/// Generates chart data for a given timeframe using provided value extractors
private func generateBidirectionalChartData(
    monthlyExtractor: @escaping (DailyAggregate) -> (positive: Double?, negative: Double?),
    yearlyExtractor: @escaping (MonthlyAggregate?) -> (positive: Double, negative: Double),
    allTimeExtractor: @escaping (YearlyAggregate?) -> (positive: Double, negative: Double),
    conversionFactor: Double = 1.0
) -> [BidirectionalChartDataPoint] {
    switch selectedTimeFrame {
    case .month:
        let calendar = Calendar.current
        let now = Date()
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let monthRange = calendar.range(of: .day, in: .month, for: now) else {
            return []
        }

        return monthRange.compactMap { day in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
            let agg = dailyAggregate(for: day)
            let (positive, negative) = monthlyExtractor(agg)

            return BidirectionalChartDataPoint(
                label: "\(day)",
                positiveValue: (positive ?? 0) * conversionFactor,
                negativeValue: (negative ?? 0) * conversionFactor,
                startDate: calendar.startOfDay(for: date),
                endDate: calendar.startOfDay(for: date).addingTimeInterval(86399)
            )
        }

    case .year:
        let currentYear = Calendar.current.component(.year, from: Date())
        let dict = monthlyAggregatesDict
        return (1...12).map { month in
            let (start, end) = dateRangeForMonth(year: currentYear, month: month)
            let agg = dict[month]
            let (positive, negative) = yearlyExtractor(agg)

            return BidirectionalChartDataPoint(
                label: monthName(for: month),
                positiveValue: positive * conversionFactor,
                negativeValue: negative * conversionFactor,
                startDate: start,
                endDate: end
            )
        }

    case .allTime:
        let dict = yearlyAggregatesDict
        return fullYearRange.map { year in
            let (start, end) = dateRangeForYear(year)
            let agg = dict[year]
            let (positive, negative) = allTimeExtractor(agg)

            return BidirectionalChartDataPoint(
                label: "\(year)",
                positiveValue: positive * conversionFactor,
                negativeValue: negative * conversionFactor,
                startDate: start,
                endDate: end
            )
        }

    case .daily:
        return []
    }
}

/// Generates chart data for single-direction charts
private func generateChartData(
    monthlyExtractor: @escaping (DailyAggregate) -> Double?,
    yearlyExtractor: @escaping (MonthlyAggregate?) -> Double,
    allTimeExtractor: @escaping (YearlyAggregate?) -> Double,
    conversionFactor: Double = 1.0
) -> [ChartDataPoint] {
    switch selectedTimeFrame {
    case .month:
        let calendar = Calendar.current
        let now = Date()
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let monthRange = calendar.range(of: .day, in: .month, for: now) else {
            return []
        }

        return monthRange.compactMap { day in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
            let agg = dailyAggregate(for: day)
            guard let value = monthlyExtractor(agg) else { return nil }

            return ChartDataPoint(
                label: "\(day)",
                value: value * conversionFactor,
                startDate: calendar.startOfDay(for: date),
                endDate: calendar.startOfDay(for: date).addingTimeInterval(86399)
            )
        }

    case .year:
        let currentYear = Calendar.current.component(.year, from: Date())
        let dict = monthlyAggregatesDict
        return (1...12).map { month in
            let (start, end) = dateRangeForMonth(year: currentYear, month: month)
            let agg = dict[month]
            let value = yearlyExtractor(agg)

            return ChartDataPoint(
                label: monthName(for: month),
                value: value * conversionFactor,
                startDate: start,
                endDate: end
            )
        }

    case .allTime:
        let dict = yearlyAggregatesDict
        return fullYearRange.map { year in
            let (start, end) = dateRangeForYear(year)
            let agg = dict[year]
            let value = allTimeExtractor(agg)

            return ChartDataPoint(
                label: "\(year)",
                value: value * conversionFactor,
                startDate: start,
                endDate: end
            )
        }

    case .daily:
        return []
    }
}
```

2. Replace `chartDataForNS` (lines 479-559):
```swift
private var chartDataForNS: [BidirectionalChartDataPoint] {
    guard let home = settings.homeCoordinate else { return [] }
    let homeLat = home.latitude

    return generateBidirectionalChartData(
        monthlyExtractor: { agg in
            let positive = nsDistanceFromHome(latitude: agg.maxNorth ?? 0)
            let negative = nsDistanceFromHome(latitude: agg.maxSouth ?? 0)
            return (max(0, positive), min(0, negative))
        },
        yearlyExtractor: { agg in
            let positive = nsDistanceFromHome(latitude: agg?.maxNorth ?? homeLat)
            let negative = nsDistanceFromHome(latitude: agg?.maxSouth ?? homeLat)
            return (max(0, positive), min(0, negative))
        },
        allTimeExtractor: { agg in
            let positive = nsDistanceFromHome(latitude: agg?.maxNorth ?? homeLat)
            let negative = nsDistanceFromHome(latitude: agg?.maxSouth ?? homeLat)
            return (max(0, positive), min(0, negative))
        }
    )
}
```

3. Similarly refactor `chartDataForEW`, `chartDataForElevation`, `chartDataForDistance`

**Lines to Delete**: ~300 lines replaced with ~60 lines of extractors

**Verification**:
- Test all 4 chart types (N/S, E/W, Distance, Elevation)
- Test all 3 timeframes (Month, Year, Lifetime)
- Verify chart values match before/after

---

### Item #7: Create Generic RegionMapContainerView
**Estimated Time**: 2-3 hours

**Issue**: StatesMapView, CountriesMapView, ContinentsMapView bodies are 90% identical (lines 321-389, 446-514, 576-643)

**Pattern**:
```swift
var body: some View {
    ZStack(alignment: .top) {
        RegionMapView(/* params */)

        // Stats header
        HStack {
            Image(systemName: "flag.fill")
            Text("\(count) of \(total) \(name) visited")
        }
        .padding(/* ... */)
    }
    .navigationTitle("\(Name)")
    .toolbar { /* ... */ }
}
```

**Action Plan**: This is complex - may want to defer or keep separate. Note for future review.

---

### Item #8: Simplify RecordHistoryManager Methods
**Estimated Time**: 2-3 hours

**Issue**: Multiple overly long methods need decomposition

**Target Methods**:
1. `consolidateRecords()` (lines 419-505): 86 lines
2. `loadVisitedRegions()` (lines 215-326): 105 lines

**Action Plan for `loadVisitedRegions()`**:

Current has 3 repeated blocks:
```swift
// States conversion
let stateEntries = entries.filter { $0.recordType == RecordType.state.rawValue }
for entry in stateEntries {
    // 30+ lines of conversion logic
}

// Countries conversion
let countryEntries = entries.filter { $0.recordType == RecordType.country.rawValue }
for entry in countryEntries {
    // 30+ lines of IDENTICAL conversion logic
}

// Continents conversion
let continentEntries = entries.filter { $0.recordType == RecordType.continent.rawValue }
for entry in continentEntries {
    // 30+ lines of IDENTICAL conversion logic
}
```

**Solution**:
1. Extract conversion to RecordDetail extension:
```swift
extension RecordDetail {
    /// Creates a RecordDetail from a Core Data entry
    static func from(_ entry: RecordHistoryEntry) -> RecordDetail? {
        guard let id = entry.id,
              let timestamp = entry.timestamp,
              let recordType = entry.recordType else {
            return nil
        }

        return RecordDetail(
            id: id,
            value: entry.value,
            timestamp: timestamp,
            coordinate: CLLocationCoordinate2D(
                latitude: entry.latitude,
                longitude: entry.longitude
            ),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: recordType,
            timeFrame: .allTime,  // Regions don't have timeframes
            photoData: entry.photoData,
            photoAssetIdentifier: entry.photoAssetIdentifier,
            photoCloudIdentifier: entry.photoCloudIdentifier,
            notes: entry.notes,
            dateAdded: entry.dateAdded,
            regionCode: entry.regionCode
        )
    }
}
```

2. Simplify `loadVisitedRegions()`:
```swift
func loadVisitedRegions() {
    let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
    request.predicate = NSPredicate(
        format: "recordType IN %@",
        [RecordType.state.rawValue, RecordType.country.rawValue, RecordType.continent.rawValue]
    )
    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

    do {
        let entries = try context.fetch(request)

        // Convert and group by type
        let converted = entries.compactMap { RecordDetail.from($0) }

        visitedStates = converted.filter { $0.recordType == RecordType.state.rawValue }
        visitedCountries = converted.filter { $0.recordType == RecordType.country.rawValue }
        visitedContinents = converted.filter { $0.recordType == RecordType.continent.rawValue }

        // Update counts
        stateCount = visitedStates.count
        countryCount = visitedCountries.count
        continentCount = visitedContinents.count

    } catch {
        debugLog("❌ Error loading visited regions: \(error.localizedDescription)")
    }
}
```

**Lines Saved**: 105 lines → ~40 lines

---

### Item #9: Refactor RecordManager.checkAllRecordTypes()
**Estimated Time**: 2 hours

**Issue**: Lines 393-490 repeat identical patterns for N/S/E/W/Up/FromHome

**Current Pattern** (repeated 6x):
```swift
// Check North
if let existing = furthestNorthAllTime {
    let delta = newValue - existing.value
    if delta > settings.minLatitudeDelta {
        // 10+ lines of update logic
    }
}
```

**Action Plan**:
1. Create record check configuration:
```swift
private struct RecordCheck {
    let type: RecordType
    let timeFrame: TimeFrame
    let threshold: Double
    let shouldUpdate: (Double, Double) -> Bool  // (newValue, oldValue) -> Bool
}
```

2. Refactor to array-driven approach:
```swift
func checkAllRecordTypes(location: CLLocation, reverseGeocodedName: String?) {
    let recordChecks: [RecordCheck] = [
        RecordCheck(
            type: .north,
            timeFrame: .allTime,
            threshold: settings.minLatitudeDelta,
            shouldUpdate: { $0 - $1 > settings.minLatitudeDelta }
        ),
        // ... define all 6 record types
    ]

    for check in recordChecks {
        checkRecord(
            type: check.type,
            newValue: extractValue(for: check.type, from: location),
            threshold: check.threshold,
            shouldUpdate: check.shouldUpdate,
            location: location,
            name: reverseGeocodedName
        )
    }
}

private func checkRecord(
    type: RecordType,
    newValue: Double,
    threshold: Double,
    shouldUpdate: (Double, Double) -> Bool,
    location: CLLocation,
    name: String?
) {
    let existing = getRecord(type: type.rawValue, timeFrame: .allTime)

    guard existing == nil || shouldUpdate(newValue, existing!.value) else {
        return
    }

    // Create and set new record
    let record = RecordDetail(/* ... */)
    setRecord(type: type.rawValue, timeFrame: .allTime, record: record)

    // Save and notify
    RecordHistoryManager.shared.addRecord(recordType: type.rawValue, detail: record)
    sendNotification(for: record)
}
```

**Lines Saved**: 102 lines → ~50 lines

---

### Item #10: Extract Date Range Helpers to Utilities
**Estimated Time**: 30 minutes

**Issue**: `dateRangeForMonth()` and `dateRangeForYear()` (StatisticsView.swift lines 820-840) are duplicated elsewhere

**Action Plan**:
1. Create `/Users/dlaporte/code/GeoRecords/GeoRecords/DateUtilities.swift`:
```swift
import Foundation

// MARK: - Date Range Utilities

extension Calendar {
    /// Returns the start and end dates for a given month
    func dateRange(for year: Int, month: Int) -> (start: Date, end: Date) {
        let start = date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let end = date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? Date()
        return (start, end)
    }

    /// Returns the start and end dates for a given year
    func dateRange(for year: Int) -> (start: Date, end: Date) {
        let start = date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
        let end = date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? Date()
        return (start, end)
    }
}
```

2. Replace in StatisticsView.swift:
```swift
// Before
private func dateRangeForMonth(year: Int, month: Int) -> (Date, Date) { ... }
private func dateRangeForYear(_ year: Int) -> (Date, Date) { ... }

// After
private func dateRangeForMonth(year: Int, month: Int) -> (Date, Date) {
    Calendar.current.dateRange(for: year, month: month)
}
private func dateRangeForYear(_ year: Int) -> (Date, Date) {
    Calendar.current.dateRange(for: year)
}
```

3. Search codebase for similar date range logic and consolidate

---

## 🎯 IMPLEMENTATION ORDER

**Recommended sequence for Session 2**:

1. **Complete Item #2** (5 min)
   - Update MapsTabView to use shared RecordPhotoThumbnail
   - Delete VisitedRegionPhotoThumbnail

2. **Item #3** - RecordCardHeader (30 min)
   - Quick win, low risk

3. **Item #5** - EmptyRegionStateView (30 min)
   - Quick win, immediate cleanup

4. **Item #10** - Date utilities (30 min)
   - Quick win, sets up for #6

5. **Item #4** - Polygon bounds (1 hour)
   - Medium complexity, high value

6. **Item #6** - Chart data refactor (4-5 hours)
   - **BIGGEST WIN** - tackle when fresh
   - Most complex, highest value

7. **Item #9** - RecordManager checks (2 hours)
   - High value refactoring

8. **Item #8** - RecordHistoryManager (2-3 hours)
   - Important for maintainability

9. **Item #7** - Generic RegionMapView (2-3 hours or skip)
   - Complex, may not be worth it

---

## ✅ TESTING CHECKLIST

After each item, verify:

### Item #3 (RecordCardHeader)
- [ ] RecordsView cards display correctly
- [ ] Header shows icon, record type, and date
- [ ] Compact mode works

### Item #4 (Polygon Bounds)
- [ ] States map centers correctly
- [ ] Countries map centers correctly
- [ ] Continents map centers correctly
- [ ] Empty states work

### Item #5 (Empty State View)
- [ ] Empty states show correct icon per region type
- [ ] Text is grammatically correct (plural/singular)

### Item #6 (Chart Data)
- [ ] All 4 charts render (N/S, E/W, Distance, Elevation)
- [ ] All 3 timeframes work (Month, Year, Lifetime)
- [ ] Values match before/after refactoring
- [ ] Drag overlay still works

### Item #8 (RecordHistoryManager)
- [ ] Visited regions load correctly
- [ ] All three region types display

### Item #9 (RecordManager)
- [ ] Records still detect and save correctly
- [ ] Notifications fire appropriately
- [ ] Thresholds still apply

### Item #10 (Date Utilities)
- [ ] Charts still display correct date ranges
- [ ] Month boundaries correct
- [ ] Year boundaries correct

---

## 📊 METRICS

**Expected Results After Completion**:

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Duplicate Code | ~500 lines | ~50 lines | 90% reduction |
| SharedComponents.swift | 97 lines | ~250 lines | Reusable library |
| MapsTabView.swift | 700+ lines | ~500 lines | 30% reduction |
| StatisticsView.swift | 1600+ lines | ~1300 lines | 20% reduction |
| RecordManager.swift | ~800 lines | ~700 lines | 10% reduction |
| New utility files | 0 | 2 | Better organization |

**Total Lines Saved**: ~400-500 lines of duplicate/complex code

---

## 🚨 RISKS & MITIGATION

**Risk 1**: Chart refactoring breaks drag interactions
- **Mitigation**: Test drag extensively, keep extractors simple

**Risk 2**: Region map refactoring changes map behavior
- **Mitigation**: Take before/after screenshots, verify centering

**Risk 3**: RecordDetail.from() conversion misses edge cases
- **Mitigation**: Add nil checks, test with empty/partial data

**Risk 4**: Date utilities change boundary behavior
- **Mitigation**: Unit test date ranges, compare with current logic

---

## 📝 NOTES

- Add SharedComponents.swift to Xcode project before building
- Consider adding unit tests for new utility functions
- Document any behavior changes in commit messages
- May want to create a feature branch for this work

---

**Last Updated**: Session 1 completion
**Next Session**: Start with completing Item #2, then follow implementation order
