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
        smartNotificationsEnabled = UserDefaults.standard.bool(forKey: "smartNotificationsEnabled")
        if UserDefaults.standard.object(forKey: "smartNotificationsEnabled") == nil {
            smartNotificationsEnabled = true // Default to enabled
        }
        lastInactivityNotification = UserDefaults.standard.object(forKey: "lastInactivityNotification") as? Date
        lastFunFactNotification = UserDefaults.standard.object(forKey: "lastFunFactNotification") as? Date
    }

    func saveSettings() {
        UserDefaults.standard.set(smartNotificationsEnabled, forKey: "smartNotificationsEnabled")
        if let date = lastInactivityNotification {
            UserDefaults.standard.set(date, forKey: "lastInactivityNotification")
        }
        if let date = lastFunFactNotification {
            UserDefaults.standard.set(date, forKey: "lastFunFactNotification")
        }
    }

    // MARK: - Check for Smart Notifications
    func checkForSmartNotifications(location: CLLocation) {
        guard smartNotificationsEnabled else { return }

        // Removed near record breaking notifications (too annoying)
        // checkNearRecordBreaking(location: location)
        checkInactivity()
        checkFunFacts(location: location)
    }

    // MARK: - Near Record Breaking
    private func checkNearRecordBreaking(location: CLLocation) {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let alt = location.altitude

        let settings = SettingsManager.shared
        let recordManager = RecordManager.shared

        // Check if close to breaking any directional record
        if let furthestNorth = recordManager.furthestNorth {
            let delta = furthestNorth.value - lat
            if delta > 0 && delta <= settings.minLatitudeDelta * 2 {
                let distance = calculateDistance(delta)
                sendNearRecordNotification(
                    recordType: "Furthest North",
                    distance: distance
                )
            }
        }

        if let furthestSouth = recordManager.furthestSouth {
            let delta = lat - furthestSouth.value
            if delta > 0 && delta <= settings.minLatitudeDelta * 2 {
                let distance = calculateDistance(delta)
                sendNearRecordNotification(
                    recordType: "Furthest South",
                    distance: distance
                )
            }
        }

        if let furthestEast = recordManager.furthestEast {
            let delta = furthestEast.value - lon
            if delta > 0 && delta <= settings.minLongitudeDelta * 2 {
                let distance = calculateDistance(delta)
                sendNearRecordNotification(
                    recordType: "Furthest East",
                    distance: distance
                )
            }
        }

        if let furthestWest = recordManager.furthestWest {
            let delta = lon - furthestWest.value
            if delta > 0 && delta <= settings.minLongitudeDelta * 2 {
                let distance = calculateDistance(delta)
                sendNearRecordNotification(
                    recordType: "Furthest West",
                    distance: distance
                )
            }
        }

        // Check altitude records
        if let furthestUp = recordManager.furthestUp {
            let delta = furthestUp.value - alt
            if delta > 0 && delta <= settings.minAltitudeDeltaMeters * 2 {
                if settings.unitSystem == .imperial {
                    let feet = delta * 3.28084
                    sendNearRecordNotification(
                        recordType: "Furthest Up",
                        distance: String(format: "%.0f ft", feet)
                    )
                } else {
                    sendNearRecordNotification(
                        recordType: "Furthest Up",
                        distance: String(format: "%.0f m", delta)
                    )
                }
            }
        }

        if let furthestDown = recordManager.furthestDown {
            let delta = alt - furthestDown.value
            if delta > 0 && delta <= settings.minAltitudeDeltaMeters * 2 {
                if settings.unitSystem == .imperial {
                    let feet = delta * 3.28084
                    sendNearRecordNotification(
                        recordType: "Furthest Down",
                        distance: String(format: "%.0f ft", feet)
                    )
                } else {
                    sendNearRecordNotification(
                        recordType: "Furthest Down",
                        distance: String(format: "%.0f m", delta)
                    )
                }
            }
        }

        // Check distance from home
        if let homeCoord = settings.homeCoordinate,
           let furthestFromHome = recordManager.furthestFromHome {
            let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
            let currentDistance = location.distance(from: homeLocation)
            let recordDistance = furthestFromHome.value / 3.28084 // Convert from feet to meters
            let delta = recordDistance - currentDistance

            if delta > 0 && delta <= settings.minDistanceDeltaMeters * 2 {
                if settings.unitSystem == .imperial {
                    let miles = delta / 1609.344
                    sendNearRecordNotification(
                        recordType: "Furthest from Home",
                        distance: String(format: "%.2f mi", miles)
                    )
                } else {
                    let km = delta / 1000.0
                    sendNearRecordNotification(
                        recordType: "Furthest from Home",
                        distance: String(format: "%.2f km", km)
                    )
                }
            }
        }
    }

    private func calculateDistance(_ degrees: Double) -> String {
        // Rough conversion: 1 degree ≈ 69 miles or 111 km
        let settings = SettingsManager.shared
        if settings.unitSystem == .imperial {
            let miles = degrees * 69
            return String(format: "%.1f mi", miles)
        } else {
            let km = degrees * 111
            return String(format: "%.1f km", km)
        }
    }

    private func sendNearRecordNotification(recordType: String, distance: String) {
        let content = UNMutableNotificationContent()
        content.title = "You're close to a record!"
        content.body = "Only \(distance) away from breaking your \(recordType) record"
        content.sound = .default

        let request = UNNotificationRequest(identifier: "near-\(recordType)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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

        let request = UNNotificationRequest(identifier: "inactivity", content: content, trigger: nil)
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

        let request = UNNotificationRequest(identifier: "fun-fact", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
