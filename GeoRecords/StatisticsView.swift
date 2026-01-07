import SwiftUI
import Charts
import CoreData
import CoreLocation

// MARK: - Chart Display Constants

/// Data count threshold for reducing x-axis labels in monthly view
private let monthlyLabelThreshold = 15

/// Data count threshold for reducing x-axis labels in yearly/all-time view
private let yearlyLabelThreshold = 10

/// Show every Nth label in monthly view when crowded
private let monthlyLabelInterval = 5

/// Show years divisible by this in all-time view (e.g., 2000, 2005, 2010)
private let allTimeLabelInterval = 5

/// Y-axis padding percentage for standard charts
private let chartYAxisPadding = 0.1

/// Y-axis padding percentage for bidirectional charts
private let bidirectionalChartYAxisPadding = 0.15

// MARK: - Shared Chart Helpers

/// Fetches the most extreme record for a given type and date range
/// Used by chart cards to display location info when dragging
@MainActor
private func fetchMostExtremeRecord(recordType: String, from startDate: Date, to endDate: Date, timeFrameFilter: String? = nil) -> RecordHistoryEntry? {
    let context = PersistenceController.shared.container.viewContext
    let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

    // Build predicate based on recordType, time range, and optional timeFrame filter
    if let tfFilter = timeFrameFilter {
        request.predicate = NSPredicate(
            format: "recordType == %@ AND timestamp >= %@ AND timestamp <= %@ AND timeFrame == %@",
            recordType,
            startDate as NSDate,
            endDate as NSDate,
            tfFilter
        )
    } else {
        request.predicate = NSPredicate(
            format: "recordType == %@ AND timestamp >= %@ AND timestamp <= %@",
            recordType,
            startDate as NSDate,
            endDate as NSDate
        )
    }

    do {
        var allRecords = try context.fetch(request)

        // If no records found with timeFrame filter, try without filter as fallback
        if allRecords.isEmpty, timeFrameFilter != nil {
            request.predicate = NSPredicate(
                format: "recordType == %@ AND timestamp >= %@ AND timestamp <= %@",
                recordType,
                startDate as NSDate,
                endDate as NSDate
            )
            allRecords = try context.fetch(request)
        }

        guard !allRecords.isEmpty else { return nil }

        // Find the most recently added record for this period (respects wizard selections)
        let mostRecent = allRecords.max { r1, r2 in
            let date1 = r1.dateAdded ?? r1.timestamp ?? Date.distantPast
            let date2 = r2.dateAdded ?? r2.timestamp ?? Date.distantPast
            return date1 < date2
        }

        return mostRecent
    } catch {
        debugLog("Error fetching record for chart: \(error.localizedDescription)")
        return nil
    }
}

/// Formats a date as "Jun 2024" - used for overlay when dragging on charts
private func formatMonthYear(from date: Date) -> String {
    let calendar = Calendar.current
    let month = calendar.component(.month, from: date)
    let year = calendar.component(.year, from: date)
    let shortMonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    guard month >= 1 && month <= 12 else { return "?" }
    return "\(shortMonthNames[month - 1]) \(year)"
}

/// Determines if an x-axis label should be shown to avoid overcrowding
/// - Parameters:
///   - value: The axis value to check
///   - dataCount: Total number of data points
///   - timeFrame: Current time frame being displayed
/// - Returns: Whether to show this label
private func shouldShowXAxisLabel(for value: AxisValue, dataCount: Int, timeFrame: TimeFrame) -> Bool {
    // For monthly view (day-by-day), show every 5th day
    if timeFrame == .month && dataCount > monthlyLabelThreshold {
        if let label = value.as(String.self), let day = Int(label) {
            return day % monthlyLabelInterval == 1 || day == dataCount
        }
    }
    // For all-time view (year-by-year), show every 5th year (2000, 2005, 2010...)
    if timeFrame == .allTime && dataCount > yearlyLabelThreshold {
        if let label = value.as(String.self), let year = Int(label) {
            return year % allTimeLabelInterval == 0
        }
    }
    return true
}

struct StatisticsView: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var selectedTimeFrame: TimeFrame = .allTime
    @State private var selectedYear: Int?
    @State private var availableYears: [Int] = []
    @State private var dailyRecordsCache: [Int: [RecordHistoryEntry]] = [:]  // Day -> Records
    @State private var monthlyAggregates: [MonthlyAggregate] = []
    @State private var yearlyAggregates: [YearlyAggregate] = []
    @State private var monthlyAggregatesCache: [Int: MonthlyAggregate] = [:]
    @State private var yearlyAggregatesCache: [Int: YearlyAggregate] = [:]
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Time Frame Picker with year selection
                    StyledTimeFramePicker(
                        selection: $selectedTimeFrame,
                        selectedYear: $selectedYear,
                        availableYears: availableYears
                    )
                    .padding(.horizontal)

                    if isLoading {
                        ProgressView("Loading statistics...")
                            .padding(.top, 40)
                    } else if hasNoData {
                        NoDataView()
                    } else {
                        // Distance Section (relative to home)
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Distance")
                                .font(.headline)
                                .padding(.horizontal)

                            if settings.homeCoordinate != nil {
                                // N-S Chart (relative to home, in miles/km)
                                BidirectionalStatChartCard(
                                    title: "North / South of Home",
                                    summary: currentNSSummary,
                                    unit: settings.unitSystem.distanceUnit,
                                    positiveColor: .blue,
                                    negativeColor: .blue.opacity(0.5),
                                    positiveLabel: "N",
                                    negativeLabel: "S",
                                    data: chartDataForNS,
                                    timeFrame: effectiveTimeFrame,
                                    positiveRecordType: RecordType.north.rawValue,
                                    negativeRecordType: RecordType.south.rawValue,
                                    unitSystem: settings.unitSystem,
                                    homeCoordinate: settings.homeCoordinate,
                                    timeFrameFilter: currentTimeFrameFilter
                                )

                                // E-W Chart (relative to home, in miles/km)
                                BidirectionalStatChartCard(
                                    title: "East / West of Home",
                                    summary: currentEWSummary,
                                    unit: settings.unitSystem.distanceUnit,
                                    positiveColor: .orange,
                                    negativeColor: .orange.opacity(0.5),
                                    positiveLabel: "E",
                                    negativeLabel: "W",
                                    data: chartDataForEW,
                                    timeFrame: effectiveTimeFrame,
                                    positiveRecordType: RecordType.east.rawValue,
                                    negativeRecordType: RecordType.west.rawValue,
                                    unitSystem: settings.unitSystem,
                                    homeCoordinate: settings.homeCoordinate,
                                    timeFrameFilter: currentTimeFrameFilter
                                )

                                // Distance from Home Chart
                                StatChartCard(
                                    title: "Furthest from Home",
                                    summary: currentDistanceSummary,
                                    unit: settings.unitSystem.distanceUnit,
                                    color: .red,
                                    data: chartDataForDistance,
                                    timeFrame: effectiveTimeFrame,
                                    recordTypeToQuery: RecordType.fromHome.rawValue,
                                    unitSystem: settings.unitSystem,
                                    homeCoordinate: settings.homeCoordinate,
                                    timeFrameFilter: currentTimeFrameFilter
                                )
                            } else {
                                // Home not set - show message
                                HomeNotSetCard(message: "Set your home location in Settings to see how far you've traveled relative to home.")
                            }
                        }

                        // Elevation Section (relative to sea level)
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Elevation")
                                .font(.headline)
                                .padding(.horizontal)

                            StatChartCard(
                                title: "Highest Elevation",
                                summary: currentElevationSummary,
                                unit: settings.unitSystem.elevationUnit,
                                color: .green,
                                data: chartDataForElevation,
                                timeFrame: effectiveTimeFrame,
                                recordTypeToQuery: RecordType.up.rawValue,
                                unitSystem: settings.unitSystem,
                                homeCoordinate: nil,
                                timeFrameFilter: currentTimeFrameFilter
                            )
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Statistics")
            .onAppear {
                // Reset year selection when returning to this tab
                selectedYear = nil

                // Clean up old daily records (older than current month)
                RecordHistoryManager.shared.cleanupOldDailyRecords()

                loadAvailableYears()
                loadStatistics()

                // Check geocoding status and trigger if needed
                let pendingCount = BackgroundGeocoder.shared.pendingGeocodingCount()
                if pendingCount > 0 {
                    debugLog("📍 Stats tab: \(pendingCount) records still waiting for geocoding")
                    Task {
                        await BackgroundGeocoder.shared.geocodeMissingLocations()
                        // Reload statistics after geocoding completes to show updated location names
                        await MainActor.run {
                            loadStatistics()
                        }
                    }
                }
            }
            .onChange(of: selectedTimeFrame) { _, newValue in
                // Reset year selection when switching away from This Year
                if newValue != .year {
                    selectedYear = nil
                }
                loadStatistics()
            }
            .onChange(of: selectedYear) { _, _ in
                loadStatistics()
            }
            .onReceive(NotificationCenter.default.publisher(for: .statisticsDidChange)) { _ in
                // Reload statistics when data changes (e.g., record deleted)
                loadAvailableYears()
                loadStatistics()
            }
        }
    }

    // MARK: - Data Loading

    private func loadAvailableYears() {
        // Use RecordHistoryEntry as the source of truth for available years
        availableYears = RecordHistoryManager.shared.getAvailableYears()
    }

    private func loadStatistics() {
        isLoading = true

        Task { @MainActor in
            let historyManager = RecordHistoryManager.shared

            switch selectedTimeFrame {
            case .month:
                // Current month uses daily records for day-by-day granularity
                dailyRecordsCache = historyManager.getDailyRecordsForCurrentMonth()
                monthlyAggregates = []
                yearlyAggregates = []
                monthlyAggregatesCache = [:]
                yearlyAggregatesCache = [:]

            case .year:
                // Use specific year if selected, otherwise current year
                let yearToLoad = selectedYear ?? Calendar.current.component(.year, from: Date())
                monthlyAggregates = historyManager.getMonthlyAggregates(for: yearToLoad)
                monthlyAggregatesCache = monthlyAggregates.reduce(into: [:]) { $0[$1.month] = $1 }
                dailyRecordsCache = [:]
                yearlyAggregates = []
                yearlyAggregatesCache = [:]

            case .allTime:
                // Lifetime - aggregate by year from RecordHistoryEntry
                yearlyAggregates = historyManager.getYearlyAggregates()
                yearlyAggregatesCache = yearlyAggregates.reduce(into: [:]) { $0[$1.year] = $1 }
                dailyRecordsCache = [:]
                monthlyAggregates = []
                monthlyAggregatesCache = [:]

            case .daily:
                // Daily is not a user-visible timeframe, should not be selected
                break
            }

            isLoading = false
        }
    }

    /// Get daily aggregate for a specific day from the cache
    private func dailyAggregate(for day: Int) -> DailyAggregate {
        return RecordHistoryManager.shared.getDailyAggregate(for: day, from: dailyRecordsCache)
    }

    /// The effective time frame for display - when a specific year is selected, display like .year
    private var effectiveTimeFrame: TimeFrame {
        // selectedYear is only relevant when in .year mode now
        return selectedTimeFrame
    }

    /// The timeFrame filter string for Core Data queries
    /// Returns the appropriate timeFrame value to filter records by
    private var currentTimeFrameFilter: String? {
        switch selectedTimeFrame {
        case .month:
            return "Monthly"
        case .year:
            // When viewing a specific past year, filter by "Yearly"
            // When viewing current year, include both "Yearly" and "Monthly"
            return selectedYear != nil ? "Yearly" : nil
        case .allTime:
            return selectedYear != nil ? "Yearly" : "Lifetime"
        case .daily:
            return "Daily"
        }
    }

    // MARK: - Computed Properties for Current Values

    private var hasNoData: Bool {
        switch selectedTimeFrame {
        case .month:
            return dailyRecordsCache.isEmpty
        case .year:
            return monthlyAggregates.isEmpty
        case .allTime:
            // When a specific year is selected, we use monthlyAggregates
            if selectedYear != nil {
                return monthlyAggregates.isEmpty
            }
            return yearlyAggregates.isEmpty
        case .daily:
            return true  // Daily is not a user-visible timeframe
        }
    }

    /// Helper to get furthest record by recordType
    private func getFurthestRecord(type: String) -> (value: Double, locationName: String?)? {
        if selectedTimeFrame == .year, let year = selectedYear {
            return RecordHistoryManager.shared.getFurthestRecordForYear(type: type, year: year)
        }
        return RecordHistoryManager.shared.getFurthestRecord(type: type, timeFrame: selectedTimeFrame)
    }

    private var currentNSSummary: DirectionSummary? {
        // Get the furthest north and south records for current period
        let northRecord = getFurthestRecord(type: RecordType.north.rawValue)
        let southRecord = getFurthestRecord(type: RecordType.south.rawValue)

        guard northRecord != nil || southRecord != nil else { return nil }

        // Calculate great-circle distances from home
        let northDistance = northRecord.map { nsDistanceFromHome(latitude: $0.value) } ?? 0
        let southDistance = southRecord.map { -nsDistanceFromHome(latitude: $0.value) } ?? 0

        // Show records if they have significant distance
        let validNorth = abs(northDistance) > chartMinDistanceThreshold
        let validSouth = abs(southDistance) > chartMinDistanceThreshold

        return DirectionSummary(
            positiveLocationName: validNorth ? northRecord?.locationName : nil,
            positiveDistance: validNorth ? FormatUtils.formatDistance(abs(northDistance), unitSystem: settings.unitSystem) : "—",
            negativeLocationName: validSouth ? southRecord?.locationName : nil,
            negativeDistance: validSouth ? FormatUtils.formatDistance(abs(southDistance), unitSystem: settings.unitSystem) : "—"
        )
    }

    private var currentEWSummary: DirectionSummary? {
        // Get the furthest east and west records for current period
        let eastRecord = getFurthestRecord(type: RecordType.east.rawValue)
        let westRecord = getFurthestRecord(type: RecordType.west.rawValue)

        guard eastRecord != nil || westRecord != nil else { return nil }

        // Calculate great-circle distances from home
        let eastDistance = eastRecord.map { ewDistanceFromHome(longitude: $0.value) } ?? 0
        let westDistance = westRecord.map { -ewDistanceFromHome(longitude: $0.value) } ?? 0

        // Show records if they have significant distance
        let validEast = abs(eastDistance) > chartMinDistanceThreshold
        let validWest = abs(westDistance) > chartMinDistanceThreshold

        return DirectionSummary(
            positiveLocationName: validEast ? eastRecord?.locationName : nil,
            positiveDistance: validEast ? FormatUtils.formatDistance(abs(eastDistance), unitSystem: settings.unitSystem) : "—",
            negativeLocationName: validWest ? westRecord?.locationName : nil,
            negativeDistance: validWest ? FormatUtils.formatDistance(abs(westDistance), unitSystem: settings.unitSystem) : "—"
        )
    }

    private var currentElevationSummary: SingleDirectionSummary? {
        // Get the highest elevation record for current period
        let elevationRecord = getFurthestRecord(type: RecordType.up.rawValue)

        guard let record = elevationRecord else { return nil }

        let formattedValue: String
        if settings.unitSystem == .imperial {
            formattedValue = FormatUtils.formatFeet(record.value * metersToFeet)
        } else {
            formattedValue = FormatUtils.formatMeters(record.value)
        }

        return SingleDirectionSummary(
            locationName: record.locationName,
            formattedValue: formattedValue
        )
    }

    private var currentDistanceSummary: SingleDirectionSummary? {
        // Get the furthest from home record for current period
        let distanceRecord = getFurthestRecord(type: RecordType.fromHome.rawValue)

        guard let record = distanceRecord else { return nil }

        let formattedValue: String
        if settings.unitSystem == .imperial {
            formattedValue = FormatUtils.formatMiles(record.value / metersPerMile, decimals: 0)
        } else {
            formattedValue = FormatUtils.formatKilometers(record.value / metersPerKm, decimals: 0)
        }

        return SingleDirectionSummary(
            locationName: record.locationName,
            formattedValue: formattedValue
        )
    }

    // MARK: - Chart Data (Bidirectional)
    // N/S and E/W are relative to home location (zero = home)
    // Elevation is relative to sea level (zero = sea level)

    private var homeLat: Double {
        settings.homeCoordinate?.latitude ?? 0
    }

    private var homeLon: Double {
        settings.homeCoordinate?.longitude ?? 0
    }

    /// Home coordinate for distance calculations
    private var homeCoord: CLLocationCoordinate2D {
        settings.homeCoordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    /// Unit conversion factor (meters to display units)
    private var distanceUnitFactor: Double {
        settings.unitSystem == .imperial ? 1.0 / metersPerMile : 1.0 / metersPerKm
    }

    /// Calculate N/S distance from home to a latitude (in display units: miles or km)
    /// Returns positive for north, negative for south
    private func nsDistanceFromHome(latitude: Double) -> Double {
        guard latitude != 0 else { return 0 }
        let destination = CLLocationCoordinate2D(latitude: latitude, longitude: homeCoord.longitude)
        let distanceMeters = northSouthDistance(from: homeCoord, to: destination)
        return distanceMeters * distanceUnitFactor
    }

    /// Calculate E/W distance from home to a longitude (in display units: miles or km)
    /// Returns positive for east, negative for west
    /// Uses simple longitude comparison (not shortest-path) so Japan shows as "east" of US
    private func ewDistanceFromHome(longitude: Double) -> Double {
        guard longitude != 0 else { return 0 }
        let destination = CLLocationCoordinate2D(latitude: homeCoord.latitude, longitude: longitude)
        let distanceMeters = distanceBetween(from: homeCoord, to: destination)

        // Determine direction based on simple longitude comparison
        // East = higher longitude, West = lower longitude
        // This is more intuitive for users (Japan is "east" of US on a map)
        let isEast = longitude > homeCoord.longitude
        return (isEast ? distanceMeters : -distanceMeters) * distanceUnitFactor
    }

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

            // Get month range using DateUtilities with fallback
            guard let (monthStart, _) = calendar.currentMonthRange(for: now),
                  let monthRange = calendar.range(of: .day, in: .month, for: now) else {
                debugLog("⚠️ Failed to calculate current month range, returning empty chart data")
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
                    endDate: calendar.startOfDay(for: date).addingTimeInterval(secondsUntilEndOfDay)
                )
            }

        case .year:
            // Use selectedYear if set, otherwise current year
            let yearToUse = selectedYear ?? Calendar.current.component(.year, from: Date())
            let dict = monthlyAggregatesDict
            return (1...12).map { month in
                let (start, end) = dateRangeForMonth(year: yearToUse, month: month)
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
            // When a specific year is selected, show all 12 months
            if let year = selectedYear {
                let dict = monthlyAggregatesDict
                return (1...12).map { month in
                    let (start, end) = dateRangeForMonth(year: year, month: month)
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
            }
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

            // Get month range using DateUtilities with fallback
            guard let (monthStart, _) = calendar.currentMonthRange(for: now),
                  let monthRange = calendar.range(of: .day, in: .month, for: now) else {
                debugLog("⚠️ Failed to calculate current month range, returning empty chart data")
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
                    endDate: calendar.startOfDay(for: date).addingTimeInterval(secondsUntilEndOfDay)
                )
            }

        case .year:
            // Use selectedYear if set, otherwise current year
            let yearToUse = selectedYear ?? Calendar.current.component(.year, from: Date())
            let dict = monthlyAggregatesDict
            return (1...12).map { month in
                let (start, end) = dateRangeForMonth(year: yearToUse, month: month)
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
            // When a specific year is selected, show all 12 months
            if let year = selectedYear {
                let dict = monthlyAggregatesDict
                return (1...12).map { month in
                    let (start, end) = dateRangeForMonth(year: year, month: month)
                    let agg = dict[month]
                    let value = yearlyExtractor(agg)

                    return ChartDataPoint(
                        label: monthName(for: month),
                        value: value * conversionFactor,
                        startDate: start,
                        endDate: end
                    )
                }
            }
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

    private var chartDataForEW: [BidirectionalChartDataPoint] {
        guard let home = settings.homeCoordinate else { return [] }
        let homeLon = home.longitude

        return generateBidirectionalChartData(
            monthlyExtractor: { agg in
                let positive = ewDistanceFromHome(longitude: agg.maxEast ?? 0)
                let negative = ewDistanceFromHome(longitude: agg.maxWest ?? 0)
                return (max(0, positive), min(0, negative))
            },
            yearlyExtractor: { agg in
                let positive = ewDistanceFromHome(longitude: agg?.maxEast ?? homeLon)
                let negative = ewDistanceFromHome(longitude: agg?.maxWest ?? homeLon)
                return (max(0, positive), min(0, negative))
            },
            allTimeExtractor: { agg in
                let positive = ewDistanceFromHome(longitude: agg?.maxEast ?? homeLon)
                let negative = ewDistanceFromHome(longitude: agg?.maxWest ?? homeLon)
                return (max(0, positive), min(0, negative))
            }
        )
    }

    private var chartDataForElevation: [ChartDataPoint] {
        let conversionFactor = settings.unitSystem == .imperial ? metersToFeet : 1.0

        return generateChartData(
            monthlyExtractor: { agg in agg.maxUp },
            yearlyExtractor: { agg in agg?.maxUp ?? 0 },
            allTimeExtractor: { agg in agg?.maxUp ?? 0 },
            conversionFactor: conversionFactor
        )
    }

    private var chartDataForDistance: [ChartDataPoint] {
        let conversionFactor = settings.unitSystem == .imperial ? 1.0 / metersPerMile : 1.0 / metersPerKm

        return generateChartData(
            monthlyExtractor: { agg in agg.maxDistanceFromHome },
            yearlyExtractor: { agg in agg?.maxDistanceFromHome ?? 0 },
            allTimeExtractor: { agg in agg?.maxDistanceFromHome ?? 0 },
            conversionFactor: conversionFactor
        )
    }

    // MARK: - Year Range Helper

    /// Returns the full range of years from the earliest data to current year
    private var fullYearRange: [Int] {
        guard !yearlyAggregates.isEmpty else { return [] }
        let minYear = yearlyAggregates.map { $0.year }.min() ?? Calendar.current.component(.year, from: Date())
        let maxYear = Calendar.current.component(.year, from: Date())
        return Array(minYear...maxYear)
    }

    /// Lookup dictionary from yearly aggregates (populated during loadStatistics)
    private var yearlyAggregatesDict: [Int: YearlyAggregate] {
        yearlyAggregatesCache
    }

    /// Lookup dictionary from monthly aggregates keyed by month number (1-12) (populated during loadStatistics)
    private var monthlyAggregatesDict: [Int: MonthlyAggregate] {
        monthlyAggregatesCache
    }

    /// Short month names for chart labels
    private static let shortMonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Returns short month name for month number (1-12) - used for x-axis labels
    private func monthName(for month: Int) -> String {
        guard month >= 1 && month <= 12 else { return "?" }
        return Self.shortMonthNames[month - 1]
    }

    // MARK: - Date Range Helpers

    private func dateRangeForMonth(year: Int, month: Int) -> (start: Date, end: Date) {
        guard let range = Calendar.current.dateRange(for: year, month: month) else {
            // Fallback to current date if date calculation fails
            debugLog("⚠️ Failed to calculate date range for year \(year) month \(month)")
            let now = Date()
            return (now, now)
        }
        return range
    }

    private func dateRangeForYear(_ year: Int) -> (start: Date, end: Date) {
        guard let range = Calendar.current.dateRange(for: year) else {
            // Fallback to current date if date calculation fails
            debugLog("⚠️ Failed to calculate date range for year \(year)")
            let now = Date()
            return (now, now)
        }
        return range
    }
}

// MARK: - Chart Data Point

struct ChartDataPoint: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let value: Double
    let startDate: Date
    let endDate: Date

    static func == (lhs: ChartDataPoint, rhs: ChartDataPoint) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Bidirectional Chart Data Point (for N/S, E/W)

struct BidirectionalChartDataPoint: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let positiveValue: Double  // North, East, or Up
    let negativeValue: Double  // South or West (stored as negative)
    let startDate: Date
    let endDate: Date

    static func == (lhs: BidirectionalChartDataPoint, rhs: BidirectionalChartDataPoint) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Stat Chart Card

/// Summary for single-direction charts (Elevation, Distance from Home)
struct SingleDirectionSummary {
    let locationName: String?
    let formattedValue: String
}

struct StatChartCard: View {
    let title: String
    let summary: SingleDirectionSummary?
    let unit: String
    let color: Color
    let data: [ChartDataPoint]
    let timeFrame: TimeFrame
    let recordTypeToQuery: String
    let unitSystem: UnitSystem
    let homeCoordinate: CLLocationCoordinate2D?
    var timeFrameFilter: String? = nil  // Optional filter for Core Data queries (e.g., "Yearly" for past years)

    @State private var selectedPoint: ChartDataPoint?
    @State private var isDragging = false
    @State private var recordCache: [String: RecordHistoryEntry] = [:]  // Cache by label
    @State private var dragLocation: CGFloat = 0

    // Computed Y-axis range with padding
    private var yAxisRange: ClosedRange<Double> {
        let values = data.map { $0.value }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 1
        let range = maxVal - minVal
        let padding = range * chartYAxisPadding
        // Ensure minimum is 0 for distance charts, add padding otherwise
        let lowerBound = max(0, minVal - padding)
        let upperBound = maxVal + padding
        return lowerBound...upperBound
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header - always show title
            VStack(alignment: .leading, spacing: 8) {
                // Title or period label when dragging
                if isDragging, let point = selectedPoint {
                    // For Lifetime view (yearly bars), label is the year; for monthly views, format as "Mon YYYY"
                    Text(timeFrame == .allTime && timeFrameFilter == "Lifetime" ? point.label : formatMonthYear(from: point.startDate))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // Location row - either dragging values or default summary
                if isDragging, let point = selectedPoint {
                    // Show value for the dragged period
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(locationText(for: recordCache[point.label]))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(formatValue(point.value))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(color)
                    }
                    .transition(.opacity)
                } else if let summary = summary {
                    // Default summary row
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(summary.locationName ?? "—")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(summary.formattedValue)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(color)
                    }
                }
            }

            if data.isEmpty || data.allSatisfy({ $0.value == 0 }) {
                Text("No data for this period")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
            } else {
                Chart(data) { point in
                    BarMark(
                        x: .value("Period", point.label),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(selectedPoint?.id == point.id ? color : color.opacity(0.7))
                    .cornerRadius(4)

                    // Show rule line at selected position
                    if let selected = selectedPoint, selected.label == point.label {
                        RuleMark(x: .value("Selected", point.label))
                            .foregroundStyle(color.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 2]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        if shouldShowXAxisLabel(for: value, dataCount: data.count, timeFrame: timeFrame) {
                            AxisValueLabel()
                                .font(.caption2)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .chartYScale(domain: yAxisRange)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        // Only allow dragging for year and allTime views
                                        guard timeFrame != .month else { return }

                                        let xPosition = value.location.x
                                        dragLocation = xPosition

                                        if let label: String = proxy.value(atX: xPosition) {
                                            if let point = data.first(where: { $0.label == label }) {
                                                if selectedPoint?.label != point.label {
                                                    withAnimation(.easeInOut(duration: 0.1)) {
                                                        selectedPoint = point
                                                        isDragging = true
                                                    }
                                                    // Fetch record if not cached
                                                    if recordCache[point.label] == nil {
                                                        fetchAndCacheRecord(for: point)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            isDragging = false
                                            selectedPoint = nil
                                        }
                                    }
                            )
                    }
                }
                .frame(height: 120)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal)
        .onAppear {
            // Preload records for better drag performance (year/allTime only)
            if timeFrame != .month {
                preloadRecords()
            }
        }
        .onChange(of: data) { _, _ in
            // Clear cache when data changes
            recordCache.removeAll()
            if timeFrame != .month {
                preloadRecords()
            }
        }
    }

    private func preloadRecords() {
        Task { @MainActor in
            guard !data.isEmpty else { return }

            // Batch fetch: Get ALL records for the entire time range
            let minDate = data.map { $0.startDate }.min() ?? Date()
            let maxDate = data.map { $0.endDate }.max() ?? Date()

            let context = PersistenceController.shared.container.viewContext
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
            request.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@",
                minDate as NSDate,
                maxDate as NSDate
            )

            do {
                let allRecords = try context.fetch(request)

                // Determine what we're looking for based on recordTypeToQuery
                let targetType = RecordType.from(string: recordTypeToQuery)

                for point in data {
                    // Find all records in this period
                    let periodRecords = allRecords.filter { record in
                        guard let timestamp = record.timestamp else { return false }
                        return timestamp >= point.startDate && timestamp <= point.endDate
                    }

                    // Find the most extreme record based on the type
                    if !periodRecords.isEmpty, let type = targetType {
                        let extremeRecord: RecordHistoryEntry?

                        switch type {
                        case .up:
                            // Highest altitude
                            extremeRecord = periodRecords.max(by: { $0.altitude < $1.altitude })
                        case .fromHome:
                            // Furthest from home coordinate
                            if let home = homeCoordinate {
                                extremeRecord = periodRecords.max { r1, r2 in
                                    let dist1 = distanceBetween(
                                        from: CLLocationCoordinate2D(latitude: r1.latitude, longitude: r1.longitude),
                                        to: home
                                    )
                                    let dist2 = distanceBetween(
                                        from: CLLocationCoordinate2D(latitude: r2.latitude, longitude: r2.longitude),
                                        to: home
                                    )
                                    return dist1 < dist2
                                }
                            } else {
                                extremeRecord = nil
                            }
                        default:
                            extremeRecord = nil
                        }

                        recordCache[point.label] = extremeRecord
                    }
                }
            } catch {
                debugLog("Error batch fetching records for chart: \(error.localizedDescription)")
            }
        }
    }

    private func fetchAndCacheRecord(for point: ChartDataPoint) {
        Task { @MainActor in
            if let record = fetchMostExtremeRecord(
                recordType: recordTypeToQuery,
                from: point.startDate,
                to: point.endDate,
                timeFrameFilter: timeFrameFilter
            ) {
                recordCache[point.label] = record
            }
        }
    }

    private func locationText(for record: RecordHistoryEntry?) -> String {
        guard let record = record else { return "—" }
        if let name = record.locationName, !name.isEmpty, name != unknownLocationString {
            return name
        }
        return FormatUtils.formatCoordinates(record.latitude, record.longitude)
    }

    private func formatValue(_ value: Double) -> String {
        if recordTypeToQuery == RecordType.up.rawValue {
            if unitSystem == .imperial {
                return FormatUtils.formatFeet(value)
            } else {
                return FormatUtils.formatMeters(value)
            }
        } else {
            // Distance from home
            if unitSystem == .imperial {
                return FormatUtils.formatMiles(value, decimals: 0)
            } else {
                return FormatUtils.formatKilometers(value, decimals: 0)
            }
        }
    }

}

// MARK: - Bidirectional Stat Chart Card (for N/S, E/W)

/// Summary of furthest locations for a direction pair (N/S or E/W)
struct DirectionSummary {
    let positiveLocationName: String?
    let positiveDistance: String
    let negativeLocationName: String?
    let negativeDistance: String
}

struct BidirectionalStatChartCard: View {
    let title: String
    let summary: DirectionSummary?
    let unit: String
    let positiveColor: Color
    let negativeColor: Color
    let positiveLabel: String
    let negativeLabel: String
    let data: [BidirectionalChartDataPoint]
    let timeFrame: TimeFrame
    let positiveRecordType: String
    let negativeRecordType: String
    let unitSystem: UnitSystem
    let homeCoordinate: CLLocationCoordinate2D?
    var timeFrameFilter: String? = nil  // Optional filter for Core Data queries (e.g., "Yearly" for past years)

    @State private var selectedPoint: BidirectionalChartDataPoint?
    @State private var isDragging = false
    @State private var positiveRecordCache: [String: RecordHistoryEntry] = [:]
    @State private var negativeRecordCache: [String: RecordHistoryEntry] = [:]

    // Computed Y-axis range with 10% padding for bidirectional data
    private var yAxisRange: ClosedRange<Double> {
        let positiveValues = data.map { $0.positiveValue }
        let negativeValues = data.map { $0.negativeValue }
        let maxPositive = positiveValues.max() ?? 0
        let minNegative = negativeValues.min() ?? 0

        // Calculate range and add symmetric padding
        let absMax = max(abs(maxPositive), abs(minNegative))
        let padding = absMax * bidirectionalChartYAxisPadding

        // If data is roughly symmetric around zero, make the axis symmetric
        if maxPositive > 0 && minNegative < 0 {
            let upperBound = maxPositive + padding
            let lowerBound = minNegative - padding
            return lowerBound...upperBound
        } else if maxPositive > 0 {
            return 0...(maxPositive + padding)
        } else if minNegative < 0 {
            return (minNegative - padding)...0
        }
        return -1.0...1.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header - always show title and legend
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Title or period label when dragging
                    if isDragging, let point = selectedPoint {
                        // For Lifetime view (yearly bars), label is the year; for monthly views, format as "Mon YYYY"
                        Text(timeFrame == .allTime && timeFrameFilter == "Lifetime" ? point.label : formatMonthYear(from: point.startDate))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text(title)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Legend - always visible
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle().fill(positiveColor).frame(width: 8, height: 8)
                            Text(positiveLabel).font(.caption2).foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(negativeColor).frame(width: 8, height: 8)
                            Text(negativeLabel).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }

                // Two-row content - either dragging values or default summary
                if isDragging, let point = selectedPoint {
                    // Show values for the dragged period
                    // Use record's actual coordinates for distance (not DailyStatistic aggregates)
                    let isNS = positiveRecordType == RecordType.north.rawValue
                    let posRecord = positiveRecordCache[point.label]
                    let negRecord = negativeRecordCache[point.label]
                    let posValue = distanceFromRecord(posRecord, isNorthSouth: isNS) ?? abs(point.positiveValue)
                    let negValue = distanceFromRecord(negRecord, isNorthSouth: isNS) ?? abs(point.negativeValue)
                    let validPos = posRecord != nil && posValue > chartMinDistanceThreshold
                    let validNeg = negRecord != nil && negValue > chartMinDistanceThreshold

                    VStack(spacing: 4) {
                        // Positive direction row (N or E)
                        HStack {
                            HStack(spacing: 6) {
                                Circle().fill(positiveColor).frame(width: 6, height: 6)
                                Text(validPos ? locationText(for: posRecord) : "—")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(validPos ? formatDistance(posValue) : "—")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(positiveColor)
                        }

                        // Negative direction row (S or W) - display as positive
                        HStack {
                            HStack(spacing: 6) {
                                Circle().fill(negativeColor).frame(width: 6, height: 6)
                                Text(validNeg ? locationText(for: negRecord) : "—")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(validNeg ? formatDistance(negValue) : "—")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(negativeColor)
                        }
                    }
                    .transition(.opacity)
                } else if let summary = summary {
                    // Two-row location summary showing max for each direction
                    VStack(spacing: 4) {
                        // Positive direction row (N or E)
                        HStack {
                            HStack(spacing: 6) {
                                Circle().fill(positiveColor).frame(width: 6, height: 6)
                                Text(summary.positiveLocationName ?? "—")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(summary.positiveDistance)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(positiveColor)
                        }

                        // Negative direction row (S or W)
                        HStack {
                            HStack(spacing: 6) {
                                Circle().fill(negativeColor).frame(width: 6, height: 6)
                                Text(summary.negativeLocationName ?? "—")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(summary.negativeDistance)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(negativeColor)
                        }
                    }
                }
            }

            if data.isEmpty || data.allSatisfy({ $0.positiveValue == 0 && $0.negativeValue == 0 }) {
                Text("No data for this period")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(data) { point in
                        // Positive bar (North, East, Up)
                        BarMark(
                            x: .value("Period", point.label),
                            y: .value("Value", point.positiveValue)
                        )
                        .foregroundStyle(selectedPoint?.id == point.id ? positiveColor : positiveColor.opacity(0.7))
                        .cornerRadius(4)

                        // Negative bar (South, West)
                        BarMark(
                            x: .value("Period", point.label),
                            y: .value("Value", point.negativeValue)
                        )
                        .foregroundStyle(selectedPoint?.id == point.id ? negativeColor : negativeColor.opacity(0.7))
                        .cornerRadius(4)
                    }

                    // Zero line
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Color.gray.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1))

                    // Selection indicator
                    if let selected = selectedPoint {
                        RuleMark(x: .value("Selected", selected.label))
                            .foregroundStyle(Color.primary.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 2]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        if shouldShowXAxisLabel(for: value, dataCount: data.count, timeFrame: timeFrame) {
                            AxisValueLabel()
                                .font(.caption2)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .chartYScale(domain: yAxisRange)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard timeFrame != .month else { return }

                                        let xPosition = value.location.x
                                        if let label: String = proxy.value(atX: xPosition) {
                                            if let point = data.first(where: { $0.label == label }) {
                                                if selectedPoint?.label != point.label {
                                                    withAnimation(.easeInOut(duration: 0.1)) {
                                                        selectedPoint = point
                                                        isDragging = true
                                                    }
                                                    // Fetch records if not cached
                                                    if positiveRecordCache[point.label] == nil {
                                                        fetchAndCacheRecords(for: point)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            isDragging = false
                                            selectedPoint = nil
                                        }
                                    }
                            )
                    }
                }
                .frame(height: 140)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal)
        .onAppear {
            if timeFrame != .month {
                preloadRecords()
            }
        }
        .onChange(of: data) { _, _ in
            positiveRecordCache.removeAll()
            negativeRecordCache.removeAll()
            if timeFrame != .month {
                preloadRecords()
            }
        }
    }

    private func preloadRecords() {
        Task { @MainActor in
            guard !data.isEmpty else { return }

            // For month/year views, fetch all daily records and find extremes per period
            // For allTime view, fetch all yearly/monthly aggregates
            let minDate = data.map { $0.startDate }.min() ?? Date()
            let maxDate = data.map { $0.endDate }.max() ?? Date()

            let context = PersistenceController.shared.container.viewContext
            let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

            // Fetch ALL records in the date range (not filtered by recordType)
            // We'll find the most extreme coordinates from ALL records, not just "Furthest North" records
            request.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@",
                minDate as NSDate,
                maxDate as NSDate
            )

            do {
                let allRecords = try context.fetch(request)

                // For each data point, find the records with the most extreme coordinates
                let isNS = positiveRecordType == RecordType.north.rawValue

                for point in data {
                    // Find all records in this period
                    let periodRecords = allRecords.filter { record in
                        guard let timestamp = record.timestamp else { return false }
                        return timestamp >= point.startDate && timestamp <= point.endDate
                    }

                    if !periodRecords.isEmpty {
                        if isNS {
                            // For N/S: find record with highest latitude (north) and lowest latitude (south)
                            if let northRecord = periodRecords.max(by: { $0.latitude < $1.latitude }) {
                                positiveRecordCache[point.label] = northRecord
                            }
                            if let southRecord = periodRecords.min(by: { $0.latitude < $1.latitude }) {
                                negativeRecordCache[point.label] = southRecord
                            }
                        } else {
                            // For E/W: find record with highest longitude (east) and lowest longitude (west)
                            if let eastRecord = periodRecords.max(by: { $0.longitude < $1.longitude }) {
                                positiveRecordCache[point.label] = eastRecord
                            }
                            if let westRecord = periodRecords.min(by: { $0.longitude < $1.longitude }) {
                                negativeRecordCache[point.label] = westRecord
                            }
                        }
                    }
                }
            } catch {
                debugLog("Error batch fetching bidirectional records for chart: \(error.localizedDescription)")
            }
        }
    }

    private func locationText(for record: RecordHistoryEntry?) -> String {
        guard let record = record else { return "—" }
        if let name = record.locationName, !name.isEmpty, name != unknownLocationString {
            return name
        }
        return FormatUtils.formatCoordinates(record.latitude, record.longitude)
    }

    private func formatDistance(_ value: Double) -> String {
        FormatUtils.formatDistance(value, unitSystem: unitSystem)
    }

    /// Calculate N/S or E/W distance from record's coordinates to home
    /// Uses the record's actual latitude/longitude rather than DailyStatistic aggregates
    private func distanceFromRecord(_ record: RecordHistoryEntry?, isNorthSouth: Bool) -> Double? {
        guard let record = record, let home = homeCoordinate else { return nil }

        let distanceUnitFactor = unitSystem == .imperial ? 1.0 / metersPerMile : 1.0 / metersPerKm

        if isNorthSouth {
            // N/S distance based on latitude
            let destination = CLLocationCoordinate2D(latitude: record.latitude, longitude: home.longitude)
            let distanceMeters = northSouthDistance(from: home, to: destination)
            return abs(distanceMeters) * distanceUnitFactor
        } else {
            // E/W distance based on longitude
            let destination = CLLocationCoordinate2D(latitude: home.latitude, longitude: record.longitude)
            let distanceMeters = distanceBetween(from: home, to: destination)
            return distanceMeters * distanceUnitFactor
        }
    }

    private func fetchAndCacheRecords(for point: BidirectionalChartDataPoint) {
        Task { @MainActor in
            if let record = fetchMostExtremeRecord(recordType: positiveRecordType, from: point.startDate, to: point.endDate, timeFrameFilter: timeFrameFilter) {
                positiveRecordCache[point.label] = record
            }
            if let record = fetchMostExtremeRecord(recordType: negativeRecordType, from: point.startDate, to: point.endDate, timeFrameFilter: timeFrameFilter) {
                negativeRecordCache[point.label] = record
            }
        }
    }

}

// MARK: - No Data View

struct NoDataView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Statistics Yet")
                .font(.headline)

            Text("Start tracking your location or import photos to see your geographic footprint over time.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 60)
    }
}

// MARK: - Home Not Set Card

struct HomeNotSetCard: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.circle")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("Home Location Not Set")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal)
    }
}

// MARK: - Styled TimeFrame Picker

/// Styled segmented picker for TimeFrame that matches the Records page styling
private struct StyledTimeFramePicker: View {
    @Binding var selection: TimeFrame
    @Binding var selectedYear: Int?
    let availableYears: [Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach([TimeFrame.allTime, .year, .month], id: \.self) { timeFrame in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = timeFrame
                    }
                } label: {
                    Text(label(for: timeFrame))
                        .font(.subheadline)
                        .fontWeight(selection == timeFrame ? .semibold : .regular)
                        .foregroundColor(selection == timeFrame ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            selection == timeFrame ? Color(UIColor.systemBackground) : Color.clear
                        )
                        .cornerRadius(6)
                        .padding(2)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(UIColor.systemGray5))
        .cornerRadius(8)
        .contextMenu {
            if selection == .year && !availableYears.isEmpty {
                Button {
                    selectedYear = nil
                } label: {
                    Label("This Year", systemImage: selectedYear == nil ? "checkmark" : "calendar")
                }
                Divider()
                ForEach(availableYears, id: \.self) { year in
                    Button {
                        selectedYear = year
                    } label: {
                        Label(String(format: "%d", year), systemImage: selectedYear == year ? "checkmark" : "calendar")
                    }
                }
            }
        }
    }

    private func label(for timeFrame: TimeFrame) -> String {
        switch timeFrame {
        case .allTime:
            return "Lifetime"
        case .year:
            if let year = selectedYear {
                return String(format: "%d", year)
            }
            return "This Year"
        case .month: return "This Month"
        case .daily: return "Daily"  // Not shown in UI
        }
    }
}

// MARK: - Preview

struct StatisticsView_Previews: PreviewProvider {
    static var previews: some View {
        StatisticsView()
            .environmentObject(SettingsManager.shared)
    }
}
