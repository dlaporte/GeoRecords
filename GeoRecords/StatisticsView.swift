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
private func fetchMostExtremeRecord(recordType: String, from startDate: Date, to endDate: Date) -> RecordHistoryEntry? {
    let context = PersistenceController.shared.container.viewContext
    let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

    request.predicate = NSPredicate(
        format: "recordType == %@ AND timestamp >= %@ AND timestamp <= %@",
        recordType,
        startDate as NSDate,
        endDate as NSDate
    )

    // Sort by value to get the most extreme
    let ascending = recordType == RecordType.south.rawValue || recordType == RecordType.west.rawValue
    request.sortDescriptors = [NSSortDescriptor(key: "value", ascending: ascending)]
    request.fetchLimit = 1

    do {
        return try context.fetch(request).first
    } catch {
        debugLog("Error fetching record for chart: \(error.localizedDescription)")
        return nil
    }
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
    @State private var dailyStats: [DailyStatistic] = []
    @State private var monthlyAggregates: [MonthlyAggregate] = []
    @State private var yearlyAggregates: [YearlyAggregate] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Time Frame Picker
                    Picker("Time Frame", selection: $selectedTimeFrame) {
                        Text("Month").tag(TimeFrame.month)
                        Text("Year").tag(TimeFrame.year)
                        Text("All Years").tag(TimeFrame.allTime)
                    }
                    .pickerStyle(SegmentedPickerStyle())
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
                                    unit: settings.unitSystem == .imperial ? "mi" : "km",
                                    positiveColor: .blue,
                                    negativeColor: .blue.opacity(0.5),
                                    positiveLabel: "N",
                                    negativeLabel: "S",
                                    data: chartDataForNS,
                                    timeFrame: selectedTimeFrame,
                                    positiveRecordType: RecordType.north.rawValue,
                                    negativeRecordType: RecordType.south.rawValue,
                                    unitSystem: settings.unitSystem
                                )

                                // E-W Chart (relative to home, in miles/km)
                                BidirectionalStatChartCard(
                                    title: "East / West of Home",
                                    summary: currentEWSummary,
                                    unit: settings.unitSystem == .imperial ? "mi" : "km",
                                    positiveColor: .orange,
                                    negativeColor: .orange.opacity(0.5),
                                    positiveLabel: "E",
                                    negativeLabel: "W",
                                    data: chartDataForEW,
                                    timeFrame: selectedTimeFrame,
                                    positiveRecordType: RecordType.east.rawValue,
                                    negativeRecordType: RecordType.west.rawValue,
                                    unitSystem: settings.unitSystem
                                )

                                // Distance from Home Chart
                                StatChartCard(
                                    title: "Furthest from Home",
                                    summary: currentDistanceSummary,
                                    unit: settings.unitSystem == .imperial ? "mi" : "km",
                                    color: .red,
                                    data: chartDataForDistance,
                                    timeFrame: selectedTimeFrame,
                                    recordTypeToQuery: RecordType.fromHome.rawValue,
                                    unitSystem: settings.unitSystem
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
                                unit: settings.unitSystem == .imperial ? "ft" : "m",
                                color: .green,
                                data: chartDataForElevation,
                                timeFrame: selectedTimeFrame,
                                recordTypeToQuery: RecordType.up.rawValue,
                                unitSystem: settings.unitSystem
                            )
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Statistics")
            .onAppear {
                loadStatistics()
            }
            .onChange(of: selectedTimeFrame) { _, _ in
                loadStatistics()
            }
        }
    }

    // MARK: - Data Loading

    private func loadStatistics() {
        isLoading = true

        Task { @MainActor in
            let manager = DailyStatisticManager.shared

            switch selectedTimeFrame {
            case .month:
                dailyStats = manager.fetchCurrentMonthStatistics()
                monthlyAggregates = []
                yearlyAggregates = []

            case .year:
                let yearStats = manager.fetchCurrentYearStatistics()
                monthlyAggregates = manager.aggregateByMonth(yearStats)
                dailyStats = []
                yearlyAggregates = []

            case .allTime:
                let allStats = manager.fetchAllStatistics()
                yearlyAggregates = manager.aggregateByYear(allStats)
                dailyStats = []
                monthlyAggregates = []
            }

            isLoading = false
        }
    }

    // MARK: - Computed Properties for Current Values

    private var hasNoData: Bool {
        switch selectedTimeFrame {
        case .month:
            return dailyStats.isEmpty
        case .year:
            return monthlyAggregates.isEmpty
        case .allTime:
            return yearlyAggregates.isEmpty
        }
    }

    private var currentNSSummary: DirectionSummary? {
        let timeFrame: TimeFrame = selectedTimeFrame

        // Get the furthest north and south records for current period
        let northRecord = RecordHistoryManager.shared.getFurthestRecord(
            type: RecordType.north.rawValue,
            timeFrame: timeFrame
        )
        let southRecord = RecordHistoryManager.shared.getFurthestRecord(
            type: RecordType.south.rawValue,
            timeFrame: timeFrame
        )

        guard northRecord != nil || southRecord != nil else { return nil }

        // Calculate great-circle distances from home
        // North: positive if north of home, negative if south
        let northDistance = northRecord.map { nsDistanceFromHome(latitude: $0.value) } ?? 0
        // South: we want positive distance for display, but nsDistanceFromHome returns negative for south
        // So we negate it to get positive distance south of home
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
        let timeFrame: TimeFrame = selectedTimeFrame

        // Get the furthest east and west records for current period
        let eastRecord = RecordHistoryManager.shared.getFurthestRecord(
            type: RecordType.east.rawValue,
            timeFrame: timeFrame
        )
        let westRecord = RecordHistoryManager.shared.getFurthestRecord(
            type: RecordType.west.rawValue,
            timeFrame: timeFrame
        )

        guard eastRecord != nil || westRecord != nil else { return nil }

        // Calculate great-circle distances from home
        // East: positive if east of home, negative if west
        let eastDistance = eastRecord.map { ewDistanceFromHome(longitude: $0.value) } ?? 0
        // West: we want positive distance for display, but ewDistanceFromHome returns negative for west
        // So we negate it to get positive distance west of home
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
        let timeFrame: TimeFrame = selectedTimeFrame

        // Get the highest elevation record for current period
        let elevationRecord = RecordHistoryManager.shared.getFurthestRecord(
            type: RecordType.up.rawValue,
            timeFrame: timeFrame
        )

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
        let timeFrame: TimeFrame = selectedTimeFrame

        // Get the furthest from home record for current period
        let distanceRecord = RecordHistoryManager.shared.getFurthestRecord(
            type: RecordType.fromHome.rawValue,
            timeFrame: timeFrame
        )

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

    // MARK: - Aggregate Calculations for Current Period

    private var currentElevation: Double? {
        switch selectedTimeFrame {
        case .month:
            return dailyStats.compactMap { $0.maxUp != 0 ? $0.maxUp : nil }.max()
        case .year:
            return monthlyAggregates.compactMap { $0.maxUp }.max()
        case .allTime:
            return yearlyAggregates.compactMap { $0.maxUp }.max()
        }
    }

    private var currentDistance: Double? {
        switch selectedTimeFrame {
        case .month:
            return dailyStats.map { $0.maxDistanceFromHome }.max()
        case .year:
            return monthlyAggregates.compactMap { $0.maxDistanceFromHome }.max()
        case .allTime:
            return yearlyAggregates.compactMap { $0.maxDistanceFromHome }.max()
        }
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
    private func ewDistanceFromHome(longitude: Double) -> Double {
        guard longitude != 0 else { return 0 }
        let destination = CLLocationCoordinate2D(latitude: homeCoord.latitude, longitude: longitude)
        let distanceMeters = eastWestDistance(from: homeCoord, to: destination)
        return distanceMeters * distanceUnitFactor
    }

    private var chartDataForNS: [BidirectionalChartDataPoint] {
        switch selectedTimeFrame {
        case .month:
            let calendar = Calendar.current
            let now = Date()
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                  let monthRange = calendar.range(of: .day, in: .month, for: now) else {
                return []
            }

            let statsDict = Dictionary(uniqueKeysWithValues: dailyStats.compactMap { stat -> (Int, DailyStatistic)? in
                guard stat.date != nil else { return nil }
                return (stat.dayOfMonth, stat)
            })

            return monthRange.compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
                let stat = statsDict[day]

                let rawPositive = nsDistanceFromHome(latitude: stat?.maxNorth ?? 0)
                let rawNegative = nsDistanceFromHome(latitude: stat?.maxSouth ?? 0)

                return BidirectionalChartDataPoint(
                    label: "\(day)",
                    positiveValue: max(0, rawPositive),
                    negativeValue: min(0, rawNegative),
                    startDate: calendar.startOfDay(for: date),
                    endDate: calendar.startOfDay(for: date).addingTimeInterval(86399)
                )
            }

        case .year:
            return monthlyAggregates.map { agg in
                let (start, end) = dateRangeForMonth(year: agg.year, month: agg.month)
                let rawPositive = nsDistanceFromHome(latitude: agg.maxNorth ?? homeLat)
                let rawNegative = nsDistanceFromHome(latitude: agg.maxSouth ?? homeLat)
                return BidirectionalChartDataPoint(
                    label: agg.monthName,
                    positiveValue: max(0, rawPositive),
                    negativeValue: min(0, rawNegative),
                    startDate: start,
                    endDate: end
                )
            }

        case .allTime:
            let dict = yearlyAggregatesDict
            return fullYearRange.map { year in
                let (start, end) = dateRangeForYear(year)
                let agg = dict[year]
                let rawPositive = nsDistanceFromHome(latitude: agg?.maxNorth ?? homeLat)
                let rawNegative = nsDistanceFromHome(latitude: agg?.maxSouth ?? homeLat)
                return BidirectionalChartDataPoint(
                    label: "\(year)",
                    positiveValue: max(0, rawPositive),
                    negativeValue: min(0, rawNegative),
                    startDate: start,
                    endDate: end
                )
            }
        }
    }

    private var chartDataForEW: [BidirectionalChartDataPoint] {
        switch selectedTimeFrame {
        case .month:
            let calendar = Calendar.current
            let now = Date()
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                  let monthRange = calendar.range(of: .day, in: .month, for: now) else {
                return []
            }

            let statsDict = Dictionary(uniqueKeysWithValues: dailyStats.compactMap { stat -> (Int, DailyStatistic)? in
                guard stat.date != nil else { return nil }
                return (stat.dayOfMonth, stat)
            })

            return monthRange.compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
                let stat = statsDict[day]

                let rawPositive = ewDistanceFromHome(longitude: stat?.maxEast ?? 0)
                let rawNegative = ewDistanceFromHome(longitude: stat?.maxWest ?? 0)

                return BidirectionalChartDataPoint(
                    label: "\(day)",
                    positiveValue: max(0, rawPositive),
                    negativeValue: min(0, rawNegative),
                    startDate: calendar.startOfDay(for: date),
                    endDate: calendar.startOfDay(for: date).addingTimeInterval(86399)
                )
            }

        case .year:
            return monthlyAggregates.map { agg in
                let (start, end) = dateRangeForMonth(year: agg.year, month: agg.month)
                let rawPositive = ewDistanceFromHome(longitude: agg.maxEast ?? homeLon)
                let rawNegative = ewDistanceFromHome(longitude: agg.maxWest ?? homeLon)
                return BidirectionalChartDataPoint(
                    label: agg.monthName,
                    positiveValue: max(0, rawPositive),
                    negativeValue: min(0, rawNegative),
                    startDate: start,
                    endDate: end
                )
            }

        case .allTime:
            let dict = yearlyAggregatesDict
            return fullYearRange.map { year in
                let (start, end) = dateRangeForYear(year)
                let agg = dict[year]
                let rawPositive = ewDistanceFromHome(longitude: agg?.maxEast ?? homeLon)
                let rawNegative = ewDistanceFromHome(longitude: agg?.maxWest ?? homeLon)
                return BidirectionalChartDataPoint(
                    label: "\(year)",
                    positiveValue: max(0, rawPositive),
                    negativeValue: min(0, rawNegative),
                    startDate: start,
                    endDate: end
                )
            }
        }
    }

    private var chartDataForElevation: [ChartDataPoint] {
        let conversionFactor = settings.unitSystem == .imperial ? metersToFeet : 1.0

        switch selectedTimeFrame {
        case .month:
            // Generate all days of the month
            let calendar = Calendar.current
            let now = Date()
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                  let monthRange = calendar.range(of: .day, in: .month, for: now) else {
                return []
            }

            // Create a lookup dictionary for existing stats
            let statsDict = Dictionary(uniqueKeysWithValues: dailyStats.compactMap { stat -> (Int, DailyStatistic)? in
                guard stat.date != nil else { return nil }
                return (stat.dayOfMonth, stat)
            })

            // Generate data for all days
            return monthRange.compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }

                let stat = statsDict[day]
                let value = (stat?.maxUp ?? 0) * conversionFactor

                return ChartDataPoint(
                    label: "\(day)",
                    value: value,
                    startDate: calendar.startOfDay(for: date),
                    endDate: calendar.startOfDay(for: date).addingTimeInterval(86399)
                )
            }
        case .year:
            return monthlyAggregates.map { agg in
                let (start, end) = dateRangeForMonth(year: agg.year, month: agg.month)
                return ChartDataPoint(
                    label: agg.monthName,
                    value: (agg.maxUp ?? 0) * conversionFactor,
                    startDate: start,
                    endDate: end
                )
            }
        case .allTime:
            let dict = yearlyAggregatesDict
            return fullYearRange.map { year in
                let (start, end) = dateRangeForYear(year)
                let agg = dict[year]
                return ChartDataPoint(
                    label: "\(year)",
                    value: (agg?.maxUp ?? 0) * conversionFactor,
                    startDate: start,
                    endDate: end
                )
            }
        }
    }

    private var chartDataForDistance: [ChartDataPoint] {
        let conversionFactor = settings.unitSystem == .imperial ? 1.0 / metersPerMile : 1.0 / metersPerKm

        switch selectedTimeFrame {
        case .month:
            // Generate all days of the month
            let calendar = Calendar.current
            let now = Date()
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                  let monthRange = calendar.range(of: .day, in: .month, for: now) else {
                return []
            }

            // Create a lookup dictionary for existing stats
            let statsDict = Dictionary(uniqueKeysWithValues: dailyStats.compactMap { stat -> (Int, DailyStatistic)? in
                guard stat.date != nil else { return nil }
                return (stat.dayOfMonth, stat)
            })

            // Generate data for all days
            return monthRange.compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }

                let stat = statsDict[day]
                let value = (stat?.maxDistanceFromHome ?? 0) * conversionFactor

                return ChartDataPoint(
                    label: "\(day)",
                    value: value,
                    startDate: calendar.startOfDay(for: date),
                    endDate: calendar.startOfDay(for: date).addingTimeInterval(86399)
                )
            }
        case .year:
            return monthlyAggregates.map { agg in
                let (start, end) = dateRangeForMonth(year: agg.year, month: agg.month)
                return ChartDataPoint(
                    label: agg.monthName,
                    value: (agg.maxDistanceFromHome ?? 0) * conversionFactor,
                    startDate: start,
                    endDate: end
                )
            }
        case .allTime:
            let dict = yearlyAggregatesDict
            return fullYearRange.map { year in
                let (start, end) = dateRangeForYear(year)
                let agg = dict[year]
                return ChartDataPoint(
                    label: "\(year)",
                    value: (agg?.maxDistanceFromHome ?? 0) * conversionFactor,
                    startDate: start,
                    endDate: end
                )
            }
        }
    }

    // MARK: - Year Range Helper

    /// Returns the full range of years from the earliest data to current year
    private var fullYearRange: [Int] {
        guard !yearlyAggregates.isEmpty else { return [] }
        let minYear = yearlyAggregates.map { $0.year }.min() ?? Calendar.current.component(.year, from: Date())
        let maxYear = Calendar.current.component(.year, from: Date())
        return Array(minYear...maxYear)
    }

    /// Creates a lookup dictionary from yearly aggregates
    private var yearlyAggregatesDict: [Int: YearlyAggregate] {
        Dictionary(uniqueKeysWithValues: yearlyAggregates.map { ($0.year, $0) })
    }

    // MARK: - Date Range Helpers

    private func dateRangeForMonth(year: Int, month: Int) -> (start: Date, end: Date) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        let calendar = Calendar.current
        let start = calendar.date(from: components) ?? Date()
        let end = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: start) ?? Date()
        return (start, end)
    }

    private func dateRangeForYear(_ year: Int) -> (start: Date, end: Date) {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        let calendar = Calendar.current
        let start = calendar.date(from: components) ?? Date()
        let end = calendar.date(byAdding: DateComponents(year: 1, second: -1), to: start) ?? Date()
        return (start, end)
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
                    Text(point.label)
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
            for point in data {
                if let record = fetchMostExtremeRecord(
                    recordType: recordTypeToQuery,
                    from: point.startDate,
                    to: point.endDate
                ) {
                    recordCache[point.label] = record
                }
            }
        }
    }

    private func fetchAndCacheRecord(for point: ChartDataPoint) {
        Task { @MainActor in
            if let record = fetchMostExtremeRecord(
                recordType: recordTypeToQuery,
                from: point.startDate,
                to: point.endDate
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
        return String(format: "%.4f, %.4f", record.latitude, record.longitude)
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
                        Text(point.label)
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
                    // Both positive and negative values displayed as absolute distances
                    let posValue = abs(point.positiveValue)
                    let negValue = abs(point.negativeValue)
                    let validPos = posValue > chartMinDistanceThreshold
                    let validNeg = negValue > chartMinDistanceThreshold

                    VStack(spacing: 4) {
                        // Positive direction row (N or E)
                        HStack {
                            HStack(spacing: 6) {
                                Circle().fill(positiveColor).frame(width: 6, height: 6)
                                Text(validPos ? locationText(for: positiveRecordCache[point.label]) : "—")
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
                                Text(validNeg ? locationText(for: negativeRecordCache[point.label]) : "—")
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
            for point in data {
                if let record = fetchMostExtremeRecord(recordType: positiveRecordType, from: point.startDate, to: point.endDate) {
                    positiveRecordCache[point.label] = record
                }
                if let record = fetchMostExtremeRecord(recordType: negativeRecordType, from: point.startDate, to: point.endDate) {
                    negativeRecordCache[point.label] = record
                }
            }
        }
    }

    private func locationText(for record: RecordHistoryEntry?) -> String {
        guard let record = record else { return "—" }
        if let name = record.locationName, !name.isEmpty, name != unknownLocationString {
            return name
        }
        return String(format: "%.4f, %.4f", record.latitude, record.longitude)
    }

    private func formatDistance(_ value: Double) -> String {
        FormatUtils.formatDistance(value, unitSystem: unitSystem)
    }

    private func fetchAndCacheRecords(for point: BidirectionalChartDataPoint) {
        Task { @MainActor in
            if let record = fetchMostExtremeRecord(recordType: positiveRecordType, from: point.startDate, to: point.endDate) {
                positiveRecordCache[point.label] = record
            }
            if let record = fetchMostExtremeRecord(recordType: negativeRecordType, from: point.startDate, to: point.endDate) {
                negativeRecordCache[point.label] = record
            }
        }
    }

}

// MARK: - Bidirectional Location Overlay

private struct BidirectionalLocationOverlay: View {
    let point: BidirectionalChartDataPoint
    let positiveRecord: RecordHistoryEntry?
    let negativeRecord: RecordHistoryEntry?
    let positiveLabel: String
    let negativeLabel: String
    let positiveColor: Color
    let negativeColor: Color
    let positiveRecordType: String
    let negativeRecordType: String
    let unitSystem: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Period label
            Text(point.label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Two-row location summary
            VStack(spacing: 4) {
                // Positive direction row (N or E)
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(positiveColor).frame(width: 6, height: 6)
                        Text(locationText(for: positiveRecord))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(formatDistance(point.positiveValue))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(positiveColor)
                }

                // Negative direction row (S or W)
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(negativeColor).frame(width: 6, height: 6)
                        Text(locationText(for: negativeRecord))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(formatDistance(abs(point.negativeValue)))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(negativeColor)
                }
            }
        }
    }

    private func locationText(for record: RecordHistoryEntry?) -> String {
        guard let record = record else { return "—" }
        if let name = record.locationName, !name.isEmpty, name != unknownLocationString {
            return name
        }
        return String(format: "%.4f, %.4f", record.latitude, record.longitude)
    }

    private func formatDistance(_ value: Double) -> String {
        FormatUtils.formatDistance(value, unitSystem: unitSystem)
    }
}

// MARK: - Location Overlay (shown while dragging)

private struct LocationOverlay: View {
    let point: ChartDataPoint
    let record: RecordHistoryEntry?
    let recordType: String
    let unitSystem: UnitSystem
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            // Period label
            Text(point.label)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(color)
                .frame(minWidth: 50)

            if let record = record {
                Divider()
                    .frame(height: 20)

                // Location
                Image(systemName: "mappin.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)

                if let locationName = record.locationName, !locationName.isEmpty, locationName != unknownLocationString {
                    Text(locationName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(String(format: "%.4f, %.4f", record.latitude, record.longitude))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Value
                Text(formatValue(record))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
            } else {
                Spacer()
                Text("No record")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 44)
    }

    private func formatValue(_ record: RecordHistoryEntry) -> String {
        switch recordType {
        case RecordType.north.rawValue, RecordType.south.rawValue:
            return String(format: "%.4f°", record.value)
        case RecordType.east.rawValue, RecordType.west.rawValue:
            return String(format: "%.4f°", record.value)
        case RecordType.up.rawValue:
            if unitSystem == .imperial {
                return FormatUtils.formatFeet(record.value * metersToFeet)
            } else {
                return FormatUtils.formatMeters(record.value)
            }
        case RecordType.fromHome.rawValue:
            if unitSystem == .imperial {
                return FormatUtils.formatMiles(record.value / metersPerMile)
            } else {
                return FormatUtils.formatKilometers(record.value / metersPerKm)
            }
        default:
            return FormatUtils.formatTwoDecimal(record.value)
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

// MARK: - Preview

struct StatisticsView_Previews: PreviewProvider {
    static var previews: some View {
        StatisticsView()
            .environmentObject(SettingsManager.shared)
    }
}
