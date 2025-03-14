import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()
    
    func sendNotification(title: String, body: String, latitude: Double, longitude: Double) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["latitude": latitude, "longitude": longitude]
        // Deliver immediately.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error sending notification: \(error.localizedDescription)")
            }
        }
    }
}
