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

// MARK: - Period summary

enum PeriodSummary {
    /// "Oct 2026 · 3 records set · 1 new state"; totals in Lifetime; "nothing
    /// recorded" when every count is zero
    static func text(title: String, records: Int, states: Int, countries: Int, continents: Int, lifetime: Bool) -> String {
        var parts: [String] = []
        if records > 0 { parts.append("\(records) record\(records == 1 ? "" : "s") set") }
        let prefix = lifetime ? "" : "new "
        if states > 0 { parts.append("\(states) \(prefix)state\(states == 1 ? "" : "s")") }
        if countries > 0 { parts.append("\(countries) \(prefix)countr\(countries == 1 ? "y" : "ies")") }
        if continents > 0 { parts.append("\(continents) \(prefix)continent\(continents == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("nothing recorded") }
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

struct CountPoint: Identifiable {
    let label: String
    let value: Int
    var id: String { label }
}

struct RecordsSetCard: View {
    let points: [CountPoint]
    let total: Int

    /// Every label for up to 13 buckets, every 7th day otherwise
    private var axisLabels: [String] {
        guard points.count > 13 else { return points.map(\.label) }
        return points.enumerated().filter { $0.offset % 7 == 0 }.map(\.element.label)
    }

    var body: some View {
        StatsCardContainer(title: "Records Set") {
            Text("\(total) record\(total == 1 ? "" : "s") set")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(total > 0 ? .primary : .secondary)

            Chart(points) { point in
                BarMark(
                    x: .value("Period", point.label),
                    y: .value("Records", point.value)
                )
                .foregroundStyle(Color.accentColor)
            }
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
