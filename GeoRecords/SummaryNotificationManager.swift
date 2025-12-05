import Foundation
import UserNotifications
import CoreData

@MainActor
class SummaryNotificationManager: ObservableObject {
    static let shared = SummaryNotificationManager()

    private init() {}

    // MARK: - Schedule Summary Notifications

    /// Schedule monthly and yearly summary notifications
    func scheduleSummaryNotifications() {
        let settings = SettingsManager.shared

        // Remove existing summary notifications
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["monthly-summary", "yearly-summary"])

        // Schedule both monthly and yearly summaries if enabled
        if settings.summaryNotificationsEnabled {
            scheduleMonthly()
            scheduleYearly()
        }
    }

    private func scheduleMonthly() {
        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = getMonthlyTitle()
        content.body = getMonthlyBody()
        content.sound = .default
        content.userInfo = ["deepLink": "stats"]  // Deep link to stats page

        // Trigger: First day of next month at 8:00 AM
        var dateComponents = DateComponents()
        dateComponents.day = 1
        dateComponents.hour = 8
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "monthly-summary", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugLog("Failed to schedule monthly summary: \(error)")
            } else {
                debugLog("Monthly summary notification scheduled")
            }
        }
    }

    private func scheduleYearly() {
        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = getYearlyTitle()
        content.body = getYearlyBody()
        content.sound = .default
        content.userInfo = ["deepLink": "stats"]  // Deep link to stats page

        // Trigger: January 1st at 8:00 AM
        var dateComponents = DateComponents()
        dateComponents.month = 1
        dateComponents.day = 1
        dateComponents.hour = 8
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "yearly-summary", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugLog("Failed to schedule yearly summary: \(error)")
            } else {
                debugLog("Yearly summary notification scheduled")
            }
        }
    }

    // MARK: - Content Generation

    private func getMonthlyTitle() -> String {
        let calendar = Calendar.current
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let monthName = lastMonth.formatted(.dateTime.month(.wide))
        return "\(monthName) Summary"
    }

    private func getMonthlyBody() -> String {
        // Count records from last month
        let count = getRecordCount(forTimeFrame: .month)
        if count == 0 {
            return "No new records this month. Time to explore!"
        } else if count == 1 {
            return "You set 1 new record this month!"
        } else {
            return "You set \(count) new records this month!"
        }
    }

    private func getYearlyTitle() -> String {
        let calendar = Calendar.current
        let lastYear = calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        let year = calendar.component(.year, from: lastYear)
        return "\(year) Year in Review"
    }

    private func getYearlyBody() -> String {
        // Count records from last year
        let count = getRecordCount(forTimeFrame: .year)
        if count == 0 {
            return "No records set this year. Start exploring!"
        } else if count == 1 {
            return "You set 1 record this year!"
        } else {
            return "You set \(count) records this year!"
        }
    }

    private func getRecordCount(forTimeFrame timeFrame: TimeFrame) -> Int {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<RecordHistoryEntry> = RecordHistoryEntry.fetchRequest()

        // Get date boundaries based on timeframe
        let calendar = Calendar.current
        let now = Date()

        let startDate: Date
        switch timeFrame {
        case .month:
            // Last month (not current month)
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            startDate = calendar.dateInterval(of: .month, for: lastMonth)?.start ?? now
        case .year:
            // Last year (not current year)
            let lastYear = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            startDate = calendar.dateInterval(of: .year, for: lastYear)?.start ?? now
        case .allTime:
            startDate = Date.distantPast
        }

        request.predicate = NSPredicate(format: "timestamp >= %@ AND timeFrame == %@", startDate as NSDate, timeFrame.rawValue)

        do {
            let count = try context.count(for: request)
            return count
        } catch {
            debugLog("Failed to count records: \(error)")
            return 0
        }
    }
}
