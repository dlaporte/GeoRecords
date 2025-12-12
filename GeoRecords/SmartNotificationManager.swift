import Foundation
import CoreLocation
import UserNotifications

@MainActor
class SmartNotificationManager: ObservableObject {
    static let shared = SmartNotificationManager()

    @Published var smartNotificationsEnabled = true
    private var lastInactivityNotification: Date?
    private var lastFunFactNotification: Date?
    private let inactivityThresholdDays = 14
    private let funFactCooldownHours = 24

    private init() {
        loadSettings()
    }

    // MARK: - Settings
    func loadSettings() {
        let defaults = UserDefaults.standard
        smartNotificationsEnabled = defaults.bool(forKey: UserDefaultsKey.smartNotificationsEnabled.rawValue)
        if defaults.object(forKey: UserDefaultsKey.smartNotificationsEnabled.rawValue) == nil {
            smartNotificationsEnabled = true // Default to enabled
        }
        lastInactivityNotification = defaults.object(forKey: UserDefaultsKey.lastInactivityNotification.rawValue) as? Date
        lastFunFactNotification = defaults.object(forKey: UserDefaultsKey.lastFunFactNotification.rawValue) as? Date
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(smartNotificationsEnabled, forKey: UserDefaultsKey.smartNotificationsEnabled.rawValue)
        if let date = lastInactivityNotification {
            defaults.set(date, forKey: UserDefaultsKey.lastInactivityNotification.rawValue)
        }
        if let date = lastFunFactNotification {
            defaults.set(date, forKey: UserDefaultsKey.lastFunFactNotification.rawValue)
        }
    }

    // MARK: - Check for Smart Notifications
    func checkForSmartNotifications(location: CLLocation) {
        guard smartNotificationsEnabled else { return }

        checkInactivity()
        checkFunFacts(location: location)
    }

    // MARK: - Inactivity Check
    private func checkInactivity() {
        // Check if it's been more than 14 days since last notification
        let now = Date()
        if let lastNotification = lastInactivityNotification {
            let daysSince = Calendar.current.dateComponents([.day], from: lastNotification, to: now).day ?? 0
            if daysSince < inactivityThresholdDays {
                return // Too soon
            }
        }

        // Check if there's been any activity in the last 14 days
        let context = PersistenceController.shared.container.viewContext
        let request = RecordHistoryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 1

        do {
            if let lastRecord = try context.fetch(request).first,
               let timestamp = lastRecord.timestamp {
                let daysSinceRecord = Calendar.current.dateComponents([.day], from: timestamp, to: now).day ?? 0

                if daysSinceRecord >= inactivityThresholdDays {
                    sendInactivityNotification(days: daysSinceRecord)
                    lastInactivityNotification = now
                    saveSettings()
                }
            }
        } catch {
            debugLog("Failed to check inactivity: \(error)")
        }
    }

    private func sendInactivityNotification(days: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Time to explore!"
        content.body = "You haven't set a new record in \(days) days. Where will you go next?"
        content.sound = .default

        let request = UNNotificationRequest(identifier: NotificationIdentifier.inactivity, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Fun Facts
    private func checkFunFacts(location: CLLocation) {
        // Check cooldown
        let now = Date()
        if let lastNotification = lastFunFactNotification {
            let hoursSince = Calendar.current.dateComponents([.hour], from: lastNotification, to: now).hour ?? 0
            if hoursSince < funFactCooldownHours {
                return // Too soon
            }
        }

        // Generate fun fact
        if let funFact = generateFunFact(for: location) {
            sendFunFactNotification(fact: funFact)
            lastFunFactNotification = now
            saveSettings()
        }
    }

    private func generateFunFact(for location: CLLocation) -> String? {
        let lat = location.coordinate.latitude

        // Famous latitude comparisons
        let facts: [(range: ClosedRange<Double>, fact: String)] = [
            (40.7...40.8, "You're at the same latitude as New York City!"),
            (41.8...41.9, "You're at the same latitude as Chicago and Rome!"),
            (51.5...51.6, "You're at the same latitude as London!"),
            (48.8...48.9, "You're at the same latitude as Paris!"),
            (35.6...35.7, "You're at the same latitude as Tokyo!"),
            (37.7...37.8, "You're at the same latitude as San Francisco!"),
            (34.0...34.1, "You're at the same latitude as Los Angeles!"),
            (-33.9...(-33.8), "You're at the same latitude as Sydney!"),
            (-0.1...0.1, "You're near the Equator!"),
            (66.5...66.6, "You're at the Arctic Circle!"),
            (-66.6...(-66.5), "You're at the Antarctic Circle!"),
            (23.4...23.5, "You're at the Tropic of Cancer!"),
            (-23.5...(-23.4), "You're at the Tropic of Capricorn!")
        ]

        for (range, fact) in facts {
            if range.contains(lat) {
                return fact
            }
        }

        // Hemisphere facts
        if lat > 0 {
            return "Fun fact: You're in the Northern Hemisphere!"
        } else {
            return "Fun fact: You're in the Southern Hemisphere!"
        }
    }

    private func sendFunFactNotification(fact: String) {
        let content = UNMutableNotificationContent()
        content.title = "Did you know?"
        content.body = fact
        content.sound = .default

        let request = UNNotificationRequest(identifier: NotificationIdentifier.funFact, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
