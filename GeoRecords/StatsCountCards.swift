//
//  StatsCountCards.swift
//  GeoRecords
//
//  The Stats tab's count-based pieces: the period summary strip, the "Records
//  Set" bar card and the "Regions" growth card, plus the bucketing they share.
//

import SwiftUI
import Charts

// MARK: - Buckets

/// Splits a browsed period into chart buckets (days, months or years) the way
/// the existing extreme-value cards do
enum StatsBuckets {
    static func bucketStarts(timeFrame: TimeFrame, year: Int?, month: MonthSelection?,
                             now: Date, earliestYear: Int?, calendar: Calendar) -> [Date] {
        switch timeFrame {
        case .month:
            let anchor = month?.startDate ?? now
            guard let monthStart = calendar.dateInterval(of: .month, for: anchor)?.start,
                  let days = calendar.range(of: .day, in: .month, for: anchor) else { return [] }
            return days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
        case .year:
            let y = year ?? calendar.component(.year, from: now)
            return (1...12).compactMap { calendar.date(from: DateComponents(year: y, month: $0, day: 1)) }
        case .allTime, .daily:
            let currentYear = calendar.component(.year, from: now)
            let first = min(earliestYear ?? currentYear, currentYear)
            return (first...currentYear).compactMap { calendar.date(from: DateComponents(year: $0, month: 1, day: 1)) }
        }
    }

    static func component(for timeFrame: TimeFrame) -> Calendar.Component {
        switch timeFrame {
        case .month: return .day
        case .year: return .month
        case .allTime, .daily: return .year
        }
    }

    static func labels(for bucketStarts: [Date], timeFrame: TimeFrame, calendar: Calendar) -> [String] {
        bucketStarts.map { start in
            switch timeFrame {
            case .month: return "\(calendar.component(.day, from: start))"
            case .year: return start.formatted(.dateTime.month(.abbreviated))
            case .allTime, .daily: return "\(calendar.component(.year, from: start))"
            }
        }
    }

    /// How many dates fall in each bucket (a bucket runs to the next one's start)
    static func counts(dates: [Date], bucketStarts: [Date], component: Calendar.Component, calendar: Calendar) -> [Int] {
        bucketStarts.map { start in
            guard let end = calendar.date(byAdding: component, value: 1, to: start) else { return 0 }
            return dates.filter { $0 >= start && $0 < end }.count
        }
    }

    /// The whole browsed period, for "records set" and "new regions" counts
    static func periodInterval(timeFrame: TimeFrame, year: Int?, month: MonthSelection?, now: Date, calendar: Calendar) -> DateInterval {
        switch timeFrame {
        case .month:
            let anchor = month?.startDate ?? now
            return calendar.dateInterval(of: .month, for: anchor) ?? DateInterval(start: now, end: now)
        case .year:
            let y = year ?? calendar.component(.year, from: now)
            let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1)) ?? now
            let end = calendar.date(from: DateComponents(year: y + 1, month: 1, day: 1)) ?? now
            return DateInterval(start: start, end: end)
        case .allTime, .daily:
            return DateInterval(start: .distantPast, end: .distantFuture)
        }
    }
}

// MARK: - Which records count

/// Which records count as "set" in a browsed period: those of a larger timeframe
/// than the period itself. A month's own monthly records (and a year's yearly ones)
/// are set by the period's first fix, so counting them says nothing; in a month,
/// yearly and lifetime records count, in a year lifetime ones, in Lifetime none.
enum StatsRecordCounts {
    static func countedTimeFrames(for view: TimeFrame) -> [TimeFrame] {
        switch view {
        case .month: return [.year, .allTime]
        case .year: return [.allTime]
        case .allTime, .daily: return []
        }
    }

    /// The records that count in a view: events of the counted timeframes, and one
    /// per type and timeframe. A type holds one record per timeframe at a time, so
    /// beating "Furthest North" five times in a year is one lifetime record set,
    /// not five: only the final record of each type counts, dated when it was set.
    /// Sorted by type then timeframe.
    static func counted(_ events: [RecordEvent], in view: TimeFrame) -> [RecordEvent] {
        let counted = countedTimeFrames(for: view)
        struct Key: Hashable {
            let type: RecordType
            let timeFrame: TimeFrame
        }
        var final: [Key: RecordEvent] = [:]
        for event in events where counted.contains(event.timeFrame) {
            let key = Key(type: event.recordType, timeFrame: event.timeFrame)
            if let current = final[key], current.timestamp >= event.timestamp { continue }
            final[key] = event
        }
        return final.values.sorted {
            ($0.recordType.rawValue, $0.timeFrame.rawValue) < ($1.recordType.rawValue, $1.timeFrame.rawValue)
        }
    }

    /// "yearly" / "lifetime", as in "3 yearly records set"
    static func label(_ timeFrame: TimeFrame) -> String {
        switch timeFrame {
        case .daily: return "daily"
        case .month: return "monthly"
        case .year: return "yearly"
        case .allTime: return "lifetime"
        }
    }

    /// "yearly or lifetime" in a month, "lifetime" in a year, "" in Lifetime
    static func phrase(for view: TimeFrame) -> String {
        countedTimeFrames(for: view).map(label).joined(separator: " or ")
    }
}

// MARK: - Period summary

enum PeriodSummary {
    /// "Oct 2026 · 3 yearly records set · 1 lifetime record set · 1 new state"; the
    /// counts are record types (at most six each, see StatsRecordCounts.counted);
    /// region totals in Lifetime (which counts no records); says what is missing
    /// when every count is zero
    static func text(title: String, view: TimeFrame, yearlyRecords: Int, lifetimeRecords: Int,
                     states: Int, countries: Int, continents: Int) -> String {
        let counted = StatsRecordCounts.countedTimeFrames(for: view)
        var parts: [String] = []
        if counted.contains(.year), yearlyRecords > 0 {
            parts.append("\(yearlyRecords) yearly record\(yearlyRecords == 1 ? "" : "s") set")
        }
        if counted.contains(.allTime), lifetimeRecords > 0 {
            parts.append("\(lifetimeRecords) lifetime record\(lifetimeRecords == 1 ? "" : "s") set")
        }
        let lifetime = view == .allTime
        let prefix = lifetime ? "" : "new "
        if states > 0 { parts.append("\(states) \(prefix)state\(states == 1 ? "" : "s")") }
        if countries > 0 { parts.append("\(countries) \(prefix)countr\(countries == 1 ? "y" : "ies")") }
        if continents > 0 { parts.append("\(continents) \(prefix)continent\(continents == 1 ? "" : "s")") }
        if parts.isEmpty {
            if lifetime {
                parts.append("no regions yet")
            } else {
                parts.append("no \(StatsRecordCounts.phrase(for: view)) records")
                parts.append("no new regions")
            }
        }
        return ([title] + parts).joined(separator: " · ")
    }
}

struct PeriodSummaryStrip: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .foregroundColor(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal)
    }
}

// MARK: - Card container

/// The Stats card frame (padding, rounded secondary background, horizontal inset)
struct StatsCardContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            content()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .padding(.horizontal)
    }
}

// MARK: - Records set

/// One bar segment: records of one kind ("Yearly" / "Lifetime") in one bucket
struct CountPoint: Identifiable {
    let label: String
    let kind: String
    let value: Int
    var id: String { "\(kind)/\(label)" }
}

/// Records of the larger timeframes set in the browsed period, stacked by kind.
/// Not shown in Lifetime, where no timeframe is larger (see StatsRecordCounts).
struct RecordsSetCard: View {
    let points: [CountPoint]
    let view: TimeFrame
    let yearly: Int
    let lifetime: Int

    private var headline: String {
        var parts: [String] = []
        if yearly > 0 { parts.append("\(yearly) yearly record\(yearly == 1 ? "" : "s")") }
        if lifetime > 0 { parts.append("\(lifetime) lifetime record\(lifetime == 1 ? "" : "s")") }
        return parts.isEmpty ? "No \(StatsRecordCounts.phrase(for: view)) records" : parts.joined(separator: " · ")
    }

    private var kinds: [String] {
        var seen: [String] = []
        for point in points where !seen.contains(point.kind) { seen.append(point.kind) }
        return seen
    }

    /// Every label for up to 13 buckets, every 7th day otherwise
    private var axisLabels: [String] {
        var labels: [String] = []
        for point in points where !labels.contains(point.label) { labels.append(point.label) }
        guard labels.count > 13 else { return labels }
        return labels.enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
    }

    var body: some View {
        StatsCardContainer(title: "Records Set") {
            Text(headline)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(yearly + lifetime > 0 ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Chart(points) { point in
                BarMark(
                    x: .value("Period", point.label),
                    y: .value("Records", point.value)
                )
                .foregroundStyle(by: .value("Record", point.kind))
            }
            .chartForegroundStyleScale(["Yearly": Color.accentColor, "Lifetime": Color.orange])
            .chartLegend(kinds.count > 1 ? .visible : .hidden)
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXAxis {
                AxisMarks(values: axisLabels)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
            }
            .frame(height: 120)
        }
    }
}

// MARK: - Regions growth

struct RegionGrowthPoint: Identifiable {
    let date: Date
    let states: Int
    let countries: Int
    var id: Date { date }
}

struct RegionsGrowthCard: View {
    let points: [RegionGrowthPoint]
    let timeFrame: TimeFrame
    let totalStates: Int
    let totalCountries: Int
    let newStates: Int
    let newCountries: Int

    private var summary: String {
        var text = "\(totalStates) state\(totalStates == 1 ? "" : "s") · \(totalCountries) countr\(totalCountries == 1 ? "y" : "ies")"
        var gains: [String] = []
        if newStates > 0 { gains.append("+\(newStates) state\(newStates == 1 ? "" : "s")") }
        if newCountries > 0 { gains.append("+\(newCountries) countr\(newCountries == 1 ? "y" : "ies")") }
        if !gains.isEmpty { text += " · " + gains.joined(separator: ", ") }
        return text
    }

    private var axisFormat: Date.FormatStyle {
        switch timeFrame {
        case .month: return .dateTime.day()
        case .year: return .dateTime.month(.narrow)
        case .allTime, .daily: return .dateTime.year()
        }
    }

    var body: some View {
        StatsCardContainer(title: "Regions") {
            Text(summary)
                .font(.title3)
                .fontWeight(.bold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Regions", point.states),
                        series: .value("Kind", "States")
                    )
                    .foregroundStyle(by: .value("Kind", "States"))
                    .interpolationMethod(.stepEnd)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Regions", point.countries),
                        series: .value("Kind", "Countries")
                    )
                    .foregroundStyle(by: .value("Kind", "Countries"))
                    .interpolationMethod(.stepEnd)
                }
            }
            .chartForegroundStyleScale(["States": Color.orange, "Countries": Color.blue])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: axisFormat)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 140)
        }
    }
}
