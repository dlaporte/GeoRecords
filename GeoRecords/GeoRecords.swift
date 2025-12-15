import SwiftUI
import UserNotifications

// A simple deep-link manager.
class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()
    @Published var recordType: String? = nil
    @Published var navigateToStats = false
    @Published var pendingBackupURL: URL? = nil  // For incoming backup files
}

// Notification delegate that handles incoming notifications.
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    private override init() {
        super.init()
    }

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

        // Handle record deep link
        if let recordType = userInfo["recordType"] as? String {
            DeepLinkManager.shared.recordType = recordType
            debugLog("DeepLink: recordType set to \(recordType)")
        }

        // Handle stats page deep link
        if let deepLink = userInfo["deepLink"] as? String, deepLink == "stats" {
            Task { @MainActor in
                DeepLinkManager.shared.navigateToStats = true
                debugLog("DeepLink: navigating to stats")
            }
        }

        completionHandler()
    }
}

// Request notification permissions.
func requestNotificationPermissions() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        if let error = error {
            debugLog("Notification authorization error: \(error.localizedDescription)")
        } else {
            debugLog("Notification authorization granted: \(granted)")
        }
    }
}

@main
struct GeoRecords: App {
    @StateObject var locationManager = LocationManager.shared
    let persistenceController = PersistenceController.shared

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // Don't request notification permissions here - wait for user to approve in setup wizard

        // Schedule summary notifications
        SummaryNotificationManager.shared.scheduleSummaryNotifications()

        // Startup maintenance tasks
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // Wait 2 seconds after launch

            // Remove any duplicate records
            await MainActor.run {
                let removed = RecordHistoryManager.shared.removeDuplicates()
                if removed > 0 {
                    debugLog("🧹 Startup cleanup: removed \(removed) duplicate records")
                }
            }

            // Start background geocoding for any records missing location names
            await BackgroundGeocoder.shared.geocodeMissingLocations()

            // Generate thumbnails for existing records that don't have cached thumbnails
            // This ensures widget photos work for records imported before this feature
            await ThumbnailCache.shared.generateMissingThumbnails()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(locationManager)
                .environmentObject(DeepLinkManager.shared)
                .environmentObject(RecordManager.shared)
                .environmentObject(SettingsManager.shared)
                .environmentObject(RecordHistoryManager.shared)
                .environmentObject(persistenceController)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    // Handle deep links from widgets and other sources, and backup file imports
    private func handleDeepLink(_ url: URL) {
        // Handle file URLs (backup imports via Share/Open In)
        if url.isFileURL {
            let fileExtension = url.pathExtension.lowercased()
            if fileExtension == "georecords" || fileExtension == "json" {
                debugLog("📥 Received backup file: \(url.lastPathComponent)")
                DeepLinkManager.shared.pendingBackupURL = url
            }
            return
        }

        // Handle custom scheme URLs (from widgets)
        guard url.scheme == "georecords" else { return }

        switch url.host {
        case "records":
            // Navigate to Records tab (already default)
            debugLog("Deep link: Opening records tab from widget")
        case "stats":
            // Navigate to Stats tab
            DeepLinkManager.shared.navigateToStats = true
            debugLog("Deep link: Opening stats tab from widget")
        default:
            break
        }
    }
}
