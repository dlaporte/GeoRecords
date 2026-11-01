import Foundation
import UserNotifications

/// One summary request, planned ahead of time so the schedule is testable without
/// UNUserNotificationCenter. Each becomes a single (repeats: false) calendar trigger.
struct PlannedSummary: Equatable {
    let identifier: String
    let title: String
    let body: String
    let statsYear: Int
    let statsMonth: Int?          // nil for the yearly summary
    let fireDate: DateComponents  // year / month / day / hour / minute

    /// Deep-link payload: the Stats tab opens on exactly this period
    var userInfo: [String: Any] {
        var info: [String: Any] = ["deepLink": "stats", "statsYear": statsYear]
        if let month = statsMonth {
            info["statsMonth"] = month
        }
        return info
    }
}

@MainActor
class SummaryNotificationManager: ObservableObject {
    static let shared = SummaryNotificationManager()

    private init() {}

    /// Upcoming month boundaries that get a precise request. Twelve keeps a user who
    /// never relaunches covered for a year, well under iOS's 64 pending-request cap.
    nonisolated static let monthlyWindow = 12

    /// Identifiers used before 1.8.6: one precise request per period plus repeating
    /// generic fallbacks. Both stayed pending at once, so the 1st brought two banners
    /// five minutes apart. Cleared on every schedule so an upgrade starts clean.
    nonisolated static let legacyIdentifiers = [
        NotificationIdentifier.legacyMonthlySummary,
        NotificationIdentifier.legacyYearlySummary,
        NotificationIdentifier.legacyMonthlySummaryFallback,
        NotificationIdentifier.legacyYearlySummaryFallback
    ]

    // MARK: - Schedule Summary Notifications

    /// Schedule monthly and yearly summary notifications.
    ///
    /// Local notification content is frozen at schedule time, so each request is a
    /// precise one-shot for a specific period, named for the month/year that will
    /// just have ended when it fires. A rolling window of them is scheduled on every
    /// app launch (GeoRecords.init) and whenever the Settings toggle changes.
    /// Identifiers are deterministic per period, so rescheduling replaces in place
    /// and never stacks. The body deliberately has no record count: the period
    /// hasn't ended at schedule time, so any count would be wrong.
    func scheduleSummaryNotifications() {
        let center = UNUserNotificationCenter.current()
        let plan = Self.plannedSummaries(from: Date())

        // Clear the legacy ids and this window (the toggle-off path). Anything an
        // earlier launch scheduled outside this window has already fired.
        center.removePendingNotificationRequests(withIdentifiers: Self.legacyIdentifiers + plan.map { $0.identifier })

        guard SettingsManager.shared.summaryNotificationsEnabled else { return }

        for summary in plan {
            let content = UNMutableNotificationContent()
            content.title = summary.title
            content.body = summary.body
            content.sound = .default
            content.userInfo = summary.userInfo

            let trigger = UNCalendarNotificationTrigger(dateMatching: summary.fireDate, repeats: false)
            let request = UNNotificationRequest(identifier: summary.identifier, content: content, trigger: trigger)
            center.add(request) { error in
                if let error = error {
                    debugLog("Failed to schedule \(summary.identifier): \(error)")
                }
            }
        }
        debugLog("Scheduled \(plan.count) summary notifications (through \(plan.last?.identifier ?? "none"))")
    }

    // MARK: - Planning

    /// The summaries that should be pending as of `now`: the next twelve monthly ones
    /// (each fires on the 1st at 08:00 and names the month that just ended) and the
    /// next yearly one (Jan 1 at 08:05, staggered after December's monthly). A
    /// boundary earlier today that has already passed is skipped.
    nonisolated static func plannedSummaries(from now: Date, calendar: Calendar = .current) -> [PlannedSummary] {
        var plan: [PlannedSummary] = []

        // Monthly: the first "1st at 08:00" strictly after now, then the following months
        let monthlyBoundary = DateComponents(day: 1, hour: 8, minute: 0)
        guard var fireAt = calendar.nextDate(after: now, matching: monthlyBoundary, matchingPolicy: .nextTime) else {
            return []
        }
        for _ in 0..<monthlyWindow {
            guard let summarized = calendar.date(byAdding: .month, value: -1, to: fireAt) else { break }
            let components = calendar.dateComponents([.year, .month], from: summarized)
            guard let year = components.year, let month = components.month else { break }
            let monthName = summarized.formatted(.dateTime.month(.wide))

            plan.append(PlannedSummary(
                identifier: NotificationIdentifier.monthlySummary(year: year, month: month),
                title: "\(monthName) Summary",
                body: "Your \(monthName) travel summary is ready — see which records you set!",
                statsYear: year,
                statsMonth: month,
                fireDate: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            ))

            guard let next = calendar.date(byAdding: .month, value: 1, to: fireAt) else { break }
            fireAt = next
        }

        // Yearly: the first "Jan 1 at 08:05" strictly after now
        let yearlyBoundary = DateComponents(month: 1, day: 1, hour: 8, minute: 5)
        if let yearlyFireAt = calendar.nextDate(after: now, matching: yearlyBoundary, matchingPolicy: .nextTime) {
            let summarizedYear = calendar.component(.year, from: yearlyFireAt) - 1
            plan.append(PlannedSummary(
                identifier: NotificationIdentifier.yearlySummary(year: summarizedYear),
                title: "\(summarizedYear) Year in Review",
                body: "Your \(summarizedYear) travel summary is ready — see every record you set!",
                statsYear: summarizedYear,
                statsMonth: nil,
                fireDate: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: yearlyFireAt)
            ))
        }

        return plan
    }
}
