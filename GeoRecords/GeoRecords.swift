import SwiftUI
import UserNotifications

// A simple deep-link manager.
class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()
    @Published var recordType: String? = nil
}

// Notification delegate that handles incoming notifications.
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Present notifications in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    // When the user taps the notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let recordType = userInfo["recordType"] as? String {
            DeepLinkManager.shared.recordType = recordType
            print("DeepLink: recordType set to \(recordType)")
        }
        completionHandler()
    }
}

// Request notification permissions.
func requestNotificationPermissions() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        if let error = error {
            print("Notification authorization error: \(error.localizedDescription)")
        } else {
            print("Notification authorization granted: \(granted)")
        }
    }
}

@main
struct GeoRecords: App {
    @StateObject var locationManager = LocationManager.shared
    let persistenceController = PersistenceController.shared
    let notificationDelegate = NotificationDelegate()
    
    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        requestNotificationPermissions()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(locationManager)
                .environmentObject(DeepLinkManager.shared)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
