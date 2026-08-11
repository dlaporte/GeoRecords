import Foundation
import UserNotifications

@MainActor
class SummaryNotificationManager: ObservableObject {
    static let shared = SummaryNotificationManager()

    private init() {}

    // MARK: - Schedule Summary Notifications

    /// Schedule monthly and yearly summary notifications.
    ///
    /// Local notification content is frozen at schedule time, so these are scheduled
    /// repeats:false for the next period boundary only, with the period name derived
    /// from the actual fire date. Rescheduling happens on every app launch
    /// (GeoRecords.init) and whenever the Settings toggle changes — a user who never
    /// launches gets at most one correctly-labeled summary instead of the same stale
    /// text repeating forever. The body deliberately has no record count: the period
    /// hasn't ended at schedule time, so any count would be wrong.
    func scheduleSummaryNotifications() {
        let settings = SettingsManager.shared

        // Remove existing summary notifications
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            NotificationIdentifier.monthlySummary,
            NotificationIdentifier.yearlySummary,
            NotificationIdentifier.monthlySummaryFallback,
            NotificationIdentifier.yearlySummaryFallback
        ])

        // Schedule both monthly and yearly summaries if enabled.
        // Each period gets a precise repeats:false notification (correct month/year in
        // the text) plus an evergreen repeating fallback with generic text, so a user
        // who never relaunches still gets summaries after the first one — every launch
        // clears and reschedules both, so active users always see the precise version.
        if settings.summaryNotificationsEnabled {
            scheduleMonthly()
            scheduleYearly()
            scheduleEvergreenFallbacks()
        }
    }

    /// Generic repeating summaries that fire when the app hasn't relaunched to
    /// reschedule the precise ones. Their text names no specific period, so it can
    /// never be wrong. The precise notification always fires first at the same
    /// boundary; iOS treats these as separate identifiers, and the next launch
    /// removes both, so at most one generic banner appears per period.
    private func scheduleEvergreenFallbacks() {
        let center = UNUserNotificationCenter.current()

        var monthly = DateComponents()
        monthly.day = 1
        monthly.hour = 8
        monthly.minute = 5  // After the precise one so it reads as the follow-up

        let monthlyContent = UNMutableNotificationContent()
        monthlyContent.title = "Monthly Summary"
        monthlyContent.body = "Your monthly travel summary is ready — see which records you set!"
        monthlyContent.sound = .default
        monthlyContent.userInfo = ["deepLink": "stats"]

        center.add(UNNotificationRequest(
            identifier: NotificationIdentifier.monthlySummaryFallback,
            content: monthlyContent,
            trigger: UNCalendarNotificationTrigger(dateMatching: monthly, repeats: true)
        ))

        var yearly = DateComponents()
        yearly.month = 1
        yearly.day = 1
        yearly.hour = 8
        yearly.minute = 5

        let yearlyContent = UNMutableNotificationContent()
        yearlyContent.title = "Year in Review"
        yearlyContent.body = "Your yearly travel summary is ready — see every record you set!"
        yearlyContent.sound = .default
        yearlyContent.userInfo = ["deepLink": "stats"]

        center.add(UNNotificationRequest(
            identifier: NotificationIdentifier.yearlySummaryFallback,
            content: yearlyContent,
            trigger: UNCalendarNotificationTrigger(dateMatching: yearly, repeats: true)
        ))
    }

    private func scheduleMonthly() {
        // Trigger: first day of next month at 8:00 AM (single firing; rescheduled on launch)
        var dateComponents = DateComponents()
        dateComponents.day = 1
        dateComponents.hour = 8
        dateComponents.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)

        // Name the month that will just have ENDED when the notification fires.
        // Derived from the fire date, not from "now": scheduling on March 10 must
        // produce "March Summary" for the April 1 firing.
        let fireDate = trigger.nextTriggerDate() ?? Date()
        let summaryMonth = Calendar.current.date(byAdding: .month, value: -1, to: fireDate) ?? fireDate
        let monthName = summaryMonth.formatted(.dateTime.month(.wide))

        let content = UNMutableNotificationContent()
        content.title = "\(monthName) Summary"
        content.body = "Your \(monthName) travel summary is ready — see which records you set!"
        content.sound = .default
        content.userInfo = ["deepLink": "stats"]  // Deep link to stats page

        let request = UNNotificationRequest(identifier: NotificationIdentifier.monthlySummary, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugLog("Failed to schedule monthly summary: \(error)")
            } else {
                debugLog("Monthly summary notification scheduled: \(monthName)")
            }
        }
    }

    private func scheduleYearly() {
        // Trigger: January 1st at 8:00 AM (single firing; rescheduled on launch)
        var dateComponents = DateComponents()
        dateComponents.month = 1
        dateComponents.day = 1
        dateComponents.hour = 8
        dateComponents.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)

        // Name the year that will just have ended when the notification fires
        let fireDate = trigger.nextTriggerDate() ?? Date()
        let summaryYear = Calendar.current.component(.year, from: fireDate) - 1

        let content = UNMutableNotificationContent()
        content.title = "\(summaryYear) Year in Review"
        content.body = "Your \(summaryYear) travel summary is ready — see every record you set!"
        content.sound = .default
        content.userInfo = ["deepLink": "stats"]  // Deep link to stats page

        let request = UNNotificationRequest(identifier: NotificationIdentifier.yearlySummary, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugLog("Failed to schedule yearly summary: \(error)")
            } else {
                debugLog("Yearly summary notification scheduled: \(summaryYear)")
            }
        }
    }
}
