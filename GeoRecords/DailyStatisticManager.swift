import CoreData
import CoreLocation
import SwiftUI

/// Manages daily statistics for geographic tracking
/// These are "silent" records used for graph calculations, not shown to users as achievements
@MainActor
class DailyStatisticManager: ObservableObject {
    static let shared = DailyStatisticManager()

    private var context: NSManagedObjectContext {
        dispatchPrecondition(condition: .onQueue(.main))
        return PersistenceController.shared.container.viewContext
    }

    // MARK: - Recording Daily Extremes

    /// Track pending changes to batch save
    private var pendingChanges = 0
    private let batchSaveThreshold = dailyStatisticBatchThreshold

    /// Cache for DailyStatistic objects during batch operations
    private var statisticCache: [Date: DailyStatistic] = [:]

    /// Record a location for daily statistics tracking
    /// Call this whenever a new location is received (real-time or photo import)
    /// Set batchMode=true when importing many records to defer saves
    func recordLocation(_ location: CLLocation, date: Date? = nil, homeCoordinate: CLLocationCoordinate2D?, batchMode: Bool = false) {
        // Validate location before recording
        switch validateLocation(location) {
        case .nullIsland:
            debugLog("⚠️ Skipping Null Island location for daily statistics")
            return
        case .unrealisticAltitude(let meters):
            debugLog("⚠️ Skipping unrealistic altitude (\(Int(meters))m) for daily statistics - likely airplane")
            return
        case .valid:
            break
        }

        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let altitude = location.altitude

        let targetDate = date ?? Date()
        let dayStart = Calendar.current.startOfDay(for: targetDate)

        // Get or create the DailyStatistic for this day
        let statistic = getOrCreateStatistic(for: dayStart)

        // Update max north (higher latitude = further north)
        if statistic.maxNorth == 0 || latitude > statistic.maxNorth {
            statistic.maxNorth = latitude
        }

        // Update max south (lower latitude = further south)
        if statistic.maxSouth == 0 || latitude < statistic.maxSouth {
            statistic.maxSouth = latitude
        }

        // Update max east (higher longitude = further east, with wrapping consideration)
        if statistic.maxEast == 0 || longitude > statistic.maxEast {
            statistic.maxEast = longitude
        }

        // Update max west (lower longitude = further west)
        if statistic.maxWest == 0 || longitude < statistic.maxWest {
            statistic.maxWest = longitude
        }

        // Update max up (higher altitude)
        if statistic.maxUp == 0 || altitude > statistic.maxUp {
            statistic.maxUp = altitude
        }

        // Update max down (lower altitude)
        if statistic.maxDown == 0 || altitude < statistic.maxDown {
            statistic.maxDown = altitude
        }

        // Update max distance from home
        if let home = homeCoordinate {
            let homeLocation = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let distance = location.distance(from: homeLocation)
            if distance > statistic.maxDistanceFromHome {
                statistic.maxDistanceFromHome = distance
            }
        }

        if batchMode {
            pendingChanges += 1
            // Save periodically during batch operations
            if pendingChanges >= batchSaveThreshold {
                saveContext()
                pendingChanges = 0
            }
        } else {
            saveContext()
        }
    }

    /// Flush any pending batch changes and clear cache
    func flushBatchChanges() {
        if pendingChanges > 0 {
            saveContext()
            pendingChanges = 0
        }
        // Clear cache after batch operation
        statisticCache.removeAll()
    }

    /// Record stats for a specific record type only (used during photo import)
    /// This prevents importing a "Furthest North" photo from also recording its altitude
    func recordForRecordType(_ recordType: String, location: CLLocation, altitude: Double, date: Date, homeCoordinate: CLLocationCoordinate2D?, batchMode: Bool = false) {
        guard let type = RecordType.from(string: recordType) else { return }

        let dayStart = Calendar.current.startOfDay(for: date)
        let statistic = getOrCreateStatistic(for: dayStart)

        switch type {
        case .north:
            if statistic.maxNorth == 0 || location.coordinate.latitude > statistic.maxNorth {
                statistic.maxNorth = location.coordinate.latitude
            }
        case .south:
            if statistic.maxSouth == 0 || location.coordinate.latitude < statistic.maxSouth {
                statistic.maxSouth = location.coordinate.latitude
            }
        case .east:
            if statistic.maxEast == 0 || location.coordinate.longitude > statistic.maxEast {
                statistic.maxEast = location.coordinate.longitude
            }
        case .west:
            if statistic.maxWest == 0 || location.coordinate.longitude < statistic.maxWest {
                statistic.maxWest = location.coordinate.longitude
            }
        case .up:
            // Validate altitude before recording
            if altitude <= maxRealisticAltitudeMeters {
                if statistic.maxUp == 0 || altitude > statistic.maxUp {
                    statistic.maxUp = altitude
                }
            }
        case .fromHome:
            if let home = homeCoordinate {
                let homeLocation = CLLocation(latitude: home.latitude, longitude: home.longitude)
                let distance = location.distance(from: homeLocation)
                if distance > statistic.maxDistanceFromHome {
                    statistic.maxDistanceFromHome = distance
                }
            }
        }

        if batchMode {
            pendingChanges += 1
            if pendingChanges >= batchSaveThreshold {
                saveContext()
                pendingChanges = 0
            }
        } else {
            saveContext()
        }
    }

    /// Get or create a DailyStatistic for a specific day
    private func getOrCreateStatistic(for dayStart: Date) -> DailyStatistic {
        // Check cache first
        if let cached = statisticCache[dayStart] {
            return cached
        }

        let request: NSFetchRequest<DailyStatistic> = DailyStatistic.fetchRequest()
        request.predicate = NSPredicate(format: "date == %@", dayStart as NSDate)
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if let existing = results.first {
                statisticCache[dayStart] = existing
                return existing
            }
        } catch {
            debugLog("Error fetching DailyStatistic: \(error.localizedDescription)")
        }

        // Create new
        let newStatistic = DailyStatistic(context: context)
        newStatistic.id = UUID()
        newStatistic.date = dayStart
        newStatistic.maxNorth = 0
        newStatistic.maxSouth = 0
        newStatistic.maxEast = 0
        newStatistic.maxWest = 0
        newStatistic.maxUp = 0
        newStatistic.maxDown = 0
        newStatistic.maxDistanceFromHome = 0

        statisticCache[dayStart] = newStatistic
        return newStatistic
    }

    private func saveContext() {
        do {
            try context.save()
        } catch {
            debugLog("Error saving DailyStatistic: \(error.localizedDescription)")
        }
    }

    /// Recalculate daily statistics for a specific day based on remaining records
    /// Call this after deleting records to update the graph data
    func recalculateStatisticsForDay(_ date: Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Fetch all records for this day
        let recordRequest: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()
        recordRequest.predicate = NSPredicate(
            format: "timestamp >= %@ AND timestamp < %@",
            dayStart as NSDate,
            dayEnd as NSDate
        )

        do {
            let records = try context.fetch(recordRequest)

            if records.isEmpty {
                // No records for this day - delete the statistic entry
                let statRequest: NSFetchRequest<DailyStatistic> = DailyStatistic.fetchRequest()
                statRequest.predicate = NSPredicate(format: "date == %@", dayStart as NSDate)
                if let stat = try context.fetch(statRequest).first {
                    context.delete(stat)
                    try context.save()
                    statisticCache.removeValue(forKey: dayStart)
                }
                return
            }

            // Get or create statistic for this day
            let statistic = getOrCreateStatistic(for: dayStart)

            // Reset all values
            statistic.maxNorth = 0
            statistic.maxSouth = 0
            statistic.maxEast = 0
            statistic.maxWest = 0
            statistic.maxUp = 0
            statistic.maxDown = 0
            statistic.maxDistanceFromHome = 0

            // Recalculate from records
            let homeCoordinate = SettingsManager.shared.homeCoordinate

            for record in records {
                let lat = record.latitude
                let lon = record.longitude
                let alt = record.altitude

                // Skip invalid coordinates
                guard abs(lat) > 0.0001 || abs(lon) > 0.0001 else { continue }

                // Update directional extremes
                if statistic.maxNorth == 0 || lat > statistic.maxNorth {
                    statistic.maxNorth = lat
                }
                if statistic.maxSouth == 0 || lat < statistic.maxSouth {
                    statistic.maxSouth = lat
                }
                if statistic.maxEast == 0 || lon > statistic.maxEast {
                    statistic.maxEast = lon
                }
                if statistic.maxWest == 0 || lon < statistic.maxWest {
                    statistic.maxWest = lon
                }

                // Update altitude extremes (skip unrealistic values)
                if alt <= maxRealisticAltitudeMeters {
                    if statistic.maxUp == 0 || alt > statistic.maxUp {
                        statistic.maxUp = alt
                    }
                    if statistic.maxDown == 0 || alt < statistic.maxDown {
                        statistic.maxDown = alt
                    }
                }

                // Update distance from home
                if let home = homeCoordinate {
                    let homeLocation = CLLocation(latitude: home.latitude, longitude: home.longitude)
                    let recordLocation = CLLocation(latitude: lat, longitude: lon)
                    let distance = recordLocation.distance(from: homeLocation)
                    if distance > statistic.maxDistanceFromHome {
                        statistic.maxDistanceFromHome = distance
                    }
                }
            }

            try context.save()
            statisticCache[dayStart] = statistic
        } catch {
            debugLog("Error recalculating daily statistics: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetching Statistics for Graphs

    /// Fetch daily statistics for a date range
    func fetchStatistics(from startDate: Date, to endDate: Date) -> [DailyStatistic] {
        let request: NSFetchRequest<DailyStatistic> = DailyStatistic.fetchRequest()
        request.predicate = NSPredicate(format: "date >= %@ AND date <= %@", startDate as NSDate, endDate as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

        do {
            return try context.fetch(request)
        } catch {
            debugLog("Error fetching statistics: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch statistics for the current month (day-by-day)
    func fetchCurrentMonthStatistics() -> [DailyStatistic] {
        let calendar = Calendar.current
        let now = Date()
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else {
            return []
        }
        return fetchStatistics(from: monthStart, to: now)
    }

    /// Fetch statistics for the current year (to be aggregated by month)
    func fetchCurrentYearStatistics() -> [DailyStatistic] {
        let calendar = Calendar.current
        let now = Date()
        guard let yearStart = calendar.dateInterval(of: .year, for: now)?.start else {
            return []
        }
        return fetchStatistics(from: yearStart, to: now)
    }

    /// Fetch all statistics (to be aggregated by year)
    func fetchAllStatistics() -> [DailyStatistic] {
        let request: NSFetchRequest<DailyStatistic> = DailyStatistic.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

        do {
            return try context.fetch(request)
        } catch {
            debugLog("Error fetching all statistics: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Aggregation Helpers

    /// Aggregate daily statistics into monthly buckets
    func aggregateByMonth(_ statistics: [DailyStatistic]) -> [MonthlyAggregate] {
        let calendar = Calendar.current
        var monthlyData: [DateComponents: [DailyStatistic]] = [:]

        for stat in statistics {
            guard let date = stat.date else { continue }
            let components = calendar.dateComponents([.year, .month], from: date)
            monthlyData[components, default: []].append(stat)
        }

        return monthlyData.map { components, stats in
            MonthlyAggregate(
                year: components.year ?? 0,
                month: components.month ?? 0,
                maxNorth: stats.compactMap { $0.maxNorth != 0 ? $0.maxNorth : nil }.max(),
                maxSouth: stats.compactMap { $0.maxSouth != 0 ? $0.maxSouth : nil }.min(),
                maxEast: stats.compactMap { $0.maxEast != 0 ? $0.maxEast : nil }.max(),
                maxWest: stats.compactMap { $0.maxWest != 0 ? $0.maxWest : nil }.min(),
                maxUp: stats.compactMap { $0.maxUp != 0 ? $0.maxUp : nil }.max(),
                maxDown: stats.compactMap { $0.maxDown != 0 ? $0.maxDown : nil }.min(),
                maxDistanceFromHome: stats.map { $0.maxDistanceFromHome }.max()
            )
        }.sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }

    /// Aggregate daily statistics into yearly buckets
    func aggregateByYear(_ statistics: [DailyStatistic]) -> [YearlyAggregate] {
        let calendar = Calendar.current
        var yearlyData: [Int: [DailyStatistic]] = [:]

        for stat in statistics {
            guard let date = stat.date else { continue }
            let year = calendar.component(.year, from: date)
            yearlyData[year, default: []].append(stat)
        }

        return yearlyData.map { year, stats in
            YearlyAggregate(
                year: year,
                maxNorth: stats.compactMap { $0.maxNorth != 0 ? $0.maxNorth : nil }.max(),
                maxSouth: stats.compactMap { $0.maxSouth != 0 ? $0.maxSouth : nil }.min(),
                maxEast: stats.compactMap { $0.maxEast != 0 ? $0.maxEast : nil }.max(),
                maxWest: stats.compactMap { $0.maxWest != 0 ? $0.maxWest : nil }.min(),
                maxUp: stats.compactMap { $0.maxUp != 0 ? $0.maxUp : nil }.max(),
                maxDown: stats.compactMap { $0.maxDown != 0 ? $0.maxDown : nil }.min(),
                maxDistanceFromHome: stats.map { $0.maxDistanceFromHome }.max()
            )
        }.sorted { $0.year < $1.year }
    }

    // MARK: - Clear Data

    /// Clear all daily statistics (used when clearing all records)
    /// Uses individual deletes instead of batch delete to ensure proper CloudKit sync
    func clearAllStatistics() {
        // Clear in-memory cache first
        statisticCache.removeAll()

        let fetchRequest: NSFetchRequest<DailyStatistic> = DailyStatistic.fetchRequest()

        do {
            let allStats = try context.fetch(fetchRequest)
            let statCount = allStats.count

            // Delete each record individually to ensure CloudKit tracks the deletions
            for stat in allStats {
                context.delete(stat)
            }

            try context.save()
            debugLog("✅ Cleared \(statCount) daily statistics (will sync deletion to iCloud)")
        } catch {
            debugLog("Error clearing daily statistics: \(error.localizedDescription)")
        }
    }

    /// Regenerate all daily statistics from record history
    /// Call this after importing a backup to rebuild graph data
    func regenerateAllStatistics() {
        // Clear existing statistics first
        clearAllStatistics()

        // Fetch all record history entries
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        do {
            let records = try context.fetch(request)

            if records.isEmpty {
                debugLog("📊 No records to regenerate statistics from")
                return
            }

            // Group records by day
            let calendar = Calendar.current
            var recordsByDay: [Date: [RecordHistoryEntry]] = [:]

            for record in records {
                guard let timestamp = record.timestamp else { continue }
                let dayStart = calendar.startOfDay(for: timestamp)
                recordsByDay[dayStart, default: []].append(record)
            }

            let homeCoordinate = SettingsManager.shared.homeCoordinate

            // Calculate statistics for each day
            for (dayStart, dayRecords) in recordsByDay {
                let statistic = getOrCreateStatistic(for: dayStart)

                for record in dayRecords {
                    let lat = record.latitude
                    let lon = record.longitude
                    let alt = record.altitude

                    // Skip invalid coordinates
                    guard abs(lat) > 0.0001 || abs(lon) > 0.0001 else { continue }

                    // Update directional extremes
                    if statistic.maxNorth == 0 || lat > statistic.maxNorth {
                        statistic.maxNorth = lat
                    }
                    if statistic.maxSouth == 0 || lat < statistic.maxSouth {
                        statistic.maxSouth = lat
                    }
                    if statistic.maxEast == 0 || lon > statistic.maxEast {
                        statistic.maxEast = lon
                    }
                    if statistic.maxWest == 0 || lon < statistic.maxWest {
                        statistic.maxWest = lon
                    }

                    // Update altitude extremes
                    if alt <= maxRealisticAltitudeMeters {
                        if statistic.maxUp == 0 || alt > statistic.maxUp {
                            statistic.maxUp = alt
                        }
                        if statistic.maxDown == 0 || alt < statistic.maxDown {
                            statistic.maxDown = alt
                        }
                    }

                    // Update distance from home
                    if let home = homeCoordinate {
                        let homeLocation = CLLocation(latitude: home.latitude, longitude: home.longitude)
                        let recordLocation = CLLocation(latitude: lat, longitude: lon)
                        let distance = recordLocation.distance(from: homeLocation)
                        if distance > statistic.maxDistanceFromHome {
                            statistic.maxDistanceFromHome = distance
                        }
                    }
                }
            }

            try context.save()
            statisticCache.removeAll()
            debugLog("📊 Regenerated statistics for \(recordsByDay.count) days from \(records.count) records")

        } catch {
            debugLog("Error regenerating statistics: \(error.localizedDescription)")
        }
    }
}

// MARK: - Aggregate Data Structures

struct MonthlyAggregate: Identifiable {
    let id = UUID()
    let year: Int
    let month: Int
    let maxNorth: Double?
    let maxSouth: Double?
    let maxEast: Double?
    let maxWest: Double?
    let maxUp: Double?
    let maxDown: Double?
    let maxDistanceFromHome: Double?

    var monthName: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM"
        var components = DateComponents()
        components.month = month
        if let date = Calendar.current.date(from: components) {
            return dateFormatter.string(from: date)
        }
        return "\(month)"
    }

    var northSouthSpan: Double? {
        guard let north = maxNorth, let south = maxSouth, north != 0, south != 0 else { return nil }
        return north - south
    }

    var eastWestSpan: Double? {
        guard let east = maxEast, let west = maxWest, east != 0, west != 0 else { return nil }
        return east - west
    }

    var elevationRange: Double? {
        guard let up = maxUp, let down = maxDown, up != 0, down != 0 else { return nil }
        return up - down
    }
}

struct YearlyAggregate: Identifiable {
    let id = UUID()
    let year: Int
    let maxNorth: Double?
    let maxSouth: Double?
    let maxEast: Double?
    let maxWest: Double?
    let maxUp: Double?
    let maxDown: Double?
    let maxDistanceFromHome: Double?

    var northSouthSpan: Double? {
        guard let north = maxNorth, let south = maxSouth, north != 0, south != 0 else { return nil }
        return north - south
    }

    var eastWestSpan: Double? {
        guard let east = maxEast, let west = maxWest, east != 0, west != 0 else { return nil }
        return east - west
    }

    var elevationRange: Double? {
        guard let up = maxUp, let down = maxDown, up != 0, down != 0 else { return nil }
        return up - down
    }
}

// MARK: - DailyStatistic Extensions

extension DailyStatistic {
    var northSouthSpan: Double? {
        guard maxNorth != 0, maxSouth != 0 else { return nil }
        return maxNorth - maxSouth
    }

    var eastWestSpan: Double? {
        guard maxEast != 0, maxWest != 0 else { return nil }
        return maxEast - maxWest
    }

    var elevationRange: Double? {
        guard maxUp != 0, maxDown != 0 else { return nil }
        return maxUp - maxDown
    }

    var dayOfMonth: Int {
        guard let date = date else { return 0 }
        return Calendar.current.component(.day, from: date)
    }
}
