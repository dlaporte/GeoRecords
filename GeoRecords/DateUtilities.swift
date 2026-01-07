//
//  DateUtilities.swift
//  GeoRecords
//
//  Utility functions for date range calculations
//

import Foundation

// MARK: - Date Range Utilities

extension Calendar {
    /// Returns the start and end dates for a given month
    /// - Parameters:
    ///   - year: The year
    ///   - month: The month (1-12)
    /// - Returns: Tuple of start and end dates for the month, nil if date calculation fails
    func dateRange(for year: Int, month: Int) -> (start: Date, end: Date)? {
        guard let start = date(from: DateComponents(year: year, month: month, day: 1)),
              let end = date(byAdding: DateComponents(month: 1), to: start) else {
            return nil
        }
        return (start, end)
    }

    /// Returns the start and end dates for a given year
    /// - Parameter year: The year
    /// - Returns: Tuple of start and end dates for the year, nil if date calculation fails
    func dateRange(for year: Int) -> (start: Date, end: Date)? {
        guard let start = date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return nil
        }
        return (start, end)
    }

    /// Returns the start and end dates for the current month
    /// Uses the calendar's timezone for proper local date calculation
    /// - Parameter referenceDate: The date to use as reference (defaults to now)
    /// - Returns: Tuple of start and end dates for the current month, nil if calculation fails
    func currentMonthRange(for referenceDate: Date = Date()) -> (start: Date, end: Date)? {
        guard let monthInterval = dateInterval(of: .month, for: referenceDate) else {
            return nil
        }
        return (monthInterval.start, monthInterval.end)
    }

    /// Returns the start and end dates for the current year
    /// Uses the calendar's timezone for proper local date calculation
    /// - Parameter referenceDate: The date to use as reference (defaults to now)
    /// - Returns: Tuple of start and end dates for the current year, nil if calculation fails
    func currentYearRange(for referenceDate: Date = Date()) -> (start: Date, end: Date)? {
        guard let yearInterval = dateInterval(of: .year, for: referenceDate) else {
            return nil
        }
        return (yearInterval.start, yearInterval.end)
    }

    /// Returns the start and end dates for the current day
    /// Uses the calendar's timezone for proper local date calculation
    /// - Parameter referenceDate: The date to use as reference (defaults to now)
    /// - Returns: Tuple of start and end dates for the current day
    func currentDayRange(for referenceDate: Date = Date()) -> (start: Date, end: Date)? {
        let start = startOfDay(for: referenceDate)
        guard let end = date(byAdding: .day, value: 1, to: start) else {
            return nil
        }
        return (start, end)
    }
}
