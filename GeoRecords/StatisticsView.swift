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
    let ascending = recordType == RecordType.south.rawValue || recordType == RecordType.west.rawValue || recordType == RecordType.down.rawValue
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
                        Text("All Time").tag(TimeFrame.allTime)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)

                    if isLoading {
                        ProgressView("Loading statistics...")
                            .padding(.top, 40)
                    } else if hasNoData {
                        NoDataView()
                    } else {
                        // Geographic Footprint Section (relative to home)
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Geographic Footprint")
                                .font(.headline)
                                .padding(.horizontal)

                            if settings.homeCoordinate != nil {
                                // N-S Chart (relative to home)
                                BidirectionalStatChartCard(
                                    title: "North / South of Home",
                                    subtitle: currentNSSpanFormatted,
                                    unit: "°",
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

                                // E-W Chart (relative to home)
                                BidirectionalStatChartCard(
                                    title: "East / West of Home",
                                    subtitle: currentEWSpanFormatted,
                                    unit: "°",
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
                            } else {
                                // Home not set - show message
                                HomeNotSetCard(message: "Set your home location in Settings to see how far north, south, east, and west you've traveled relative to home.")
                            }
                        }

                        // Elevation Section (relative to sea level)
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Elevation")
                                .font(.headline)
                                .padding(.horizontal)

                            BidirectionalStatChartCard(
                                title: "Above / Below Sea Level",
                                subtitle: currentElevationFormatted,
                                unit: settings.unitSystem == .imperial ? "ft" : "m",
                                positiveColor: .green,
                                negativeColor: .green.opacity(0.5),
                                positiveLabel: "Above",
                                negativeLabel: "Below",
                                data: chartDataForElevationBidirectional,
                                timeFrame: selectedTimeFrame,
                                positiveRecordType: RecordType.up.rawValue,
                                negativeRecordType: RecordType.down.rawValue,
                                unitSystem: settings.unitSystem
                            )
                        }

                        // Distance from Home Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Distance from Home")
                                .font(.headline)
                                .padding(.horizontal)

                            if settings.homeCoordinate != nil {
                                StatChartCard(
                                    title: "Max Distance",
                                    subtitle: currentDistanceFormatted,
                                    unit: settings.unitSystem == .imperial ? "mi" : "km",
                                    color: .red,
                                    data: chartDataForDistance,
                                    timeFrame: selectedTimeFrame,
                                    recordTypeToQuery: RecordType.fromHome.rawValue,
                                    unitSystem: settings.unitSystem
                                )
                            } else {
                                HomeNotSetCard(message: "Set your home location in Settings to see how far you've traveled from home.")
                            }
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

    private var currentNSSpanFormatted: String {
        guard let span = currentNSSpan else { return "—" }
        return String(format: "%.2f°", span)
    }

    private var currentEWSpanFormatted: String {
        guard let span = currentEWSpan else { return "—" }
        return String(format: "%.2f°", span)
    }

    private var currentElevationFormatted: String {
        guard let range = currentElevation else { return "—" }
        if settings.unitSystem == .imperial {
            return String(format: "%.0f ft", range * metersToFeet)
        } else {
            return String(format: "%.0f m", range)
        }
    }

    private var currentDistanceFormatted: String {
        guard let distance = currentDistance else { return "—" }
        if settings.unitSystem == .imperial {
            return String(format: "%.1f mi", distance / metersPerMile)
        } else {
            return String(format: "%.1f km", distance / metersPerKm)
        }
    }

    // MARK: - Aggregate Calculations for Current Period

    private var currentNSSpan: Double? {
        switch selectedTimeFrame {
        case .month:
            let north = dailyStats.compactMap { $0.maxNorth != 0 ? $0.maxNorth : nil }.max()
            let south = dailyStats.compactMap { $0.maxSouth != 0 ? $0.maxSouth : nil }.min()
            guard let n = north, let s = south else { return nil }
            return n - s
        case .year:
            let north = monthlyAggregates.compactMap { $0.maxNorth }.max()
            let south = monthlyAggregates.compactMap { $0.maxSouth }.min()
            guard let n = north, let s = south else { return nil }
            return n - s
        case .allTime:
            let north = yearlyAggregates.compactMap { $0.maxNorth }.max()
            let south = yearlyAggregates.compactMap { $0.maxSouth }.min()
            guard let n = north, let s = south else { return nil }
            return n - s
        }
    }

    private var currentEWSpan: Double? {
        switch selectedTimeFrame {
        case .month:
            let east = dailyStats.compactMap { $0.maxEast != 0 ? $0.maxEast : nil }.max()
            let west = dailyStats.compactMap { $0.maxWest != 0 ? $0.maxWest : nil }.min()
            guard let e = east, let w = west else { return nil }
            return e - w
        case .year:
            let east = monthlyAggregates.compactMap { $0.maxEast }.max()
            let west = monthlyAggregates.compactMap { $0.maxWest }.min()
            guard let e = east, let w = west else { return nil }
            return e - w
        case .allTime:
            let east = yearlyAggregates.compactMap { $0.maxEast }.max()
            let west = yearlyAggregates.compactMap { $0.maxWest }.min()
            guard let e = east, let w = west else { return nil }
            return e - w
        }
    }

    private var currentElevation: Double? {
        switch selectedTimeFrame {
        case .month:
            let up = dailyStats.compactMap { $0.maxUp != 0 ? $0.maxUp : nil }.max()
            let down = dailyStats.compactMap { $0.maxDown != 0 ? $0.maxDown : nil }.min()
            guard let u = up, let d = down else { return nil }
            return u - d
        case .year:
            let up = monthlyAggregates.compactMap { $0.maxUp }.max()
            let down = monthlyAggregates.compactMap { $0.maxDown }.min()
            guard let u = up, let d = down else { return nil }
            return u - d
        case .allTime:
            let up = yearlyAggregates.compactMap { $0.maxUp }.max()
            let down = yearlyAggregates.compactMap { $0.maxDown }.min()
            guard let u = up, let d = down else { return nil }
            return u - d
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

    private var chartDataForNS: [BidirectionalChartDataPoint] {
        switch selectedTimeFrame {
        case .month:
            return dailyStats.compactMap { stat in
                guard let date = stat.date else { return nil }
                return BidirectionalChartDataPoint(
                    label: "\(stat.dayOfMonth)",
                    positiveValue: stat.maxNorth - homeLat,  // Relative to home (+ = north of home)
                    negativeValue: stat.maxSouth - homeLat,  // Relative to home (- = south of home)
                    startDate: Calendar.current.startOfDay(for: date),
                    endDate: Calendar.current.startOfDay(for: date).addingTimeInterval(86399)
                )
            }
        case .year:
            return monthlyAggregates.map { agg in
                let (start, end) = dateRangeForMonth(year: agg.year, month: agg.month)
                return BidirectionalChartDataPoint(
                    label: agg.monthName,
                    positiveValue: (agg.maxNorth ?? homeLat) - homeLat,
                    negativeValue: (agg.maxSouth ?? homeLat) - homeLat,
                    startDate: start,
                    endDate: end
                )
            }
        case .allTime:
            return yearlyAggregates.map { agg in
                let (start, end) = dateRangeForYear(agg.year)
                return BidirectionalChartDataPoint(
                    label: "\(agg.year)",
                    positiveValue: (agg.maxNorth ?? homeLat) - homeLat,
                    negativeValue: (agg.maxSouth ?? homeLat) - homeLat,
                    startDate: start,
                    endDate: end
                )
            }
        }
    }

    private var chartDataForEW: [BidirectionalChartDataPoint] {
        switch selectedTimeFrame {
        case .month:
            return dailyStats.compactMap { stat in
                guard let date = stat.date else { return nil }
                return BidirectionalChartDataPoint(
                    label: "\(stat.dayOfMonth)",
                    positiveValue: stat.maxEast - homeLon,   // Relative to home (+ = east of home)
                    negativeValue: stat.maxWest - homeLon,   // Relative to home (- = west of home)
                    startDate: Calendar.current.startOfDay(for: date),
                    endDate: Calendar.current.startOfDay(for: date).addingTimeInterval(86399)
                )
            }
        case .year:
            return monthlyAggregates.map { agg in
                let (start, end) = dateRangeForMonth(year: agg.year, month: agg.month)
                return BidirectionalChartDataPoint(
                    label: agg.monthName,
                    positiveValue: (agg.maxEast ?? homeLon) - homeLon,
                    negativeValue: (agg.maxWest ?? homeLon) - homeLon,
                    startDate: start,
                    endDate: end
                )
            }
        case .allTime:
            return yearlyAggregates.map { agg in
                let (start, end) = dateRangeForYear(agg.year)
                return BidirectionalChartDataPoint(
                    label: "\(agg.year)",
                    positiveValue: (agg.maxEast ?? homeLon) - homeLon,
                    negativeValue: (agg.maxWest ?? homeLon) - homeLon,
                    startDate: start,
                    endDate: end
                )
            }
        }
    }

    private var chartDataForElevationBidirectional: [BidirectionalChartDataPoint] {
        let conversionFactor = settings.unitSystem == .imperial ? metersToFeet : 1.0

        switch selectedTimeFrame {
        case .month:
            return dailyStats.compactMap { stat in
                guard let date = stat.date else { return nil }
                return BidirectionalChartDataPoint(
                    label: "\(stat.dayOfMonth)",
                    positiveValue: stat.maxUp * conversionFactor,    // Above sea level
                    negativeValue: stat.maxDown * conversionFactor,  // Below sea level (if negative)
                    startDate: Calendar.current.startOfDay(for: date),
                    endDate: Calendar.current.startOfDay(for: date).addingTimeInterval(86399)
                )
            }
        case .year:
            return monthlyAggregates.map { agg in
                let (start, end) = dateRangeForMonth(year: agg.year, month: agg.month)
                return BidirectionalChartDataPoint(
                    label: agg.monthName,
                    positiveValue: (agg.maxUp ?? 0) * conversionFactor,
                    negativeValue: (agg.maxDown ?? 0) * conversionFactor,
                    startDate: start,
                    endDate: end
                )
            }
        case .allTime:
            return yearlyAggregates.map { agg in
                let (start, end) = dateRangeForYear(agg.year)
                return BidirectionalChartDataPoint(
                    label: "\(agg.year)",
                    positiveValue: (agg.maxUp ?? 0) * conversionFactor,
                    negativeValue: (agg.maxDown ?? 0) * conversionFactor,
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
            return dailyStats.compactMap { stat in
                guard let date = stat.date else { return nil }
                return ChartDataPoint(
                    label: "\(stat.dayOfMonth)",
                    value: stat.maxDistanceFromHome * conversionFactor,
                    startDate: Calendar.current.startOfDay(for: date),
                    endDate: Calendar.current.startOfDay(for: date).addingTimeInterval(86399)
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
            return yearlyAggregates.map { agg in
                let (start, end) = dateRangeForYear(agg.year)
                return ChartDataPoint(
                    label: "\(agg.year)",
                    value: (agg.maxDistanceFromHome ?? 0) * conversionFactor,
                    startDate: start,
                    endDate: end
                )
            }
        }
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

// MARK: - Bidirectional Chart Data Point (for N/S, E/W, Up/Down)

struct BidirectionalChartDataPoint: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let positiveValue: Double  // North, East, or Up
    let negativeValue: Double  // South, West, or Down (stored as negative)
    let startDate: Date
    let endDate: Date

    static func == (lhs: BidirectionalChartDataPoint, rhs: BidirectionalChartDataPoint) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Stat Chart Card

struct StatChartCard: View {
    let title: String
    let subtitle: String
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
            // Header with title/subtitle OR location info when dragging
            if isDragging, let point = selectedPoint {
                // Show location info while dragging
                LocationOverlay(
                    point: point,
                    record: recordCache[point.label],
                    recordType: recordTypeToQuery,
                    unitSystem: unitSystem,
                    color: color
                )
                .transition(.opacity)
            } else {
                // Normal header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text(subtitle)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(color)
                    }

                    Spacer()
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

}

// MARK: - Bidirectional Stat Chart Card (for N/S, E/W, Up/Down)

struct BidirectionalStatChartCard: View {
    let title: String
    let subtitle: String
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
            // Header with title/subtitle OR location info when dragging
            if isDragging, let point = selectedPoint {
                // Show both locations while dragging
                BidirectionalLocationOverlay(
                    point: point,
                    positiveRecord: positiveRecordCache[point.label],
                    negativeRecord: negativeRecordCache[point.label],
                    positiveLabel: positiveLabel,
                    negativeLabel: negativeLabel,
                    positiveColor: positiveColor,
                    negativeColor: negativeColor,
                    positiveRecordType: positiveRecordType,
                    negativeRecordType: negativeRecordType,
                    unitSystem: unitSystem
                )
                .transition(.opacity)
            } else {
                // Normal header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text(subtitle)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(positiveColor)
                    }

                    Spacer()

                    // Legend
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

                        // Negative bar (South, West, Down)
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
        VStack(alignment: .leading, spacing: 4) {
            // Period label
            Text(point.label)
                .font(.subheadline)
                .fontWeight(.bold)

            HStack(spacing: 12) {
                // Positive record info
                HStack(spacing: 4) {
                    Circle().fill(positiveColor).frame(width: 6, height: 6)
                    if let record = positiveRecord {
                        Text(locationText(for: record))
                            .font(.caption2)
                            .lineLimit(1)
                    } else {
                        Text("No \(positiveLabel)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Negative record info
                HStack(spacing: 4) {
                    Circle().fill(negativeColor).frame(width: 6, height: 6)
                    if let record = negativeRecord {
                        Text(locationText(for: record))
                            .font(.caption2)
                            .lineLimit(1)
                    } else {
                        Text("No \(negativeLabel)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
        }
        .frame(height: 44)
    }

    private func locationText(for record: RecordHistoryEntry) -> String {
        if let name = record.locationName, !name.isEmpty, name != unknownLocationString {
            return name
        }
        return String(format: "%.2f, %.2f", record.latitude, record.longitude)
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
                    Text(String(format: "%.2f, %.2f", record.latitude, record.longitude))
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
            return String(format: "%.2f°", record.value)
        case RecordType.east.rawValue, RecordType.west.rawValue:
            return String(format: "%.2f°", record.value)
        case RecordType.up.rawValue, RecordType.down.rawValue:
            if unitSystem == .imperial {
                return String(format: "%.0f ft", record.value * metersToFeet)
            } else {
                return String(format: "%.0f m", record.value)
            }
        case RecordType.fromHome.rawValue:
            if unitSystem == .imperial {
                return String(format: "%.1f mi", record.value / metersPerMile)
            } else {
                return String(format: "%.1f km", record.value / metersPerKm)
            }
        default:
            return String(format: "%.2f", record.value)
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
