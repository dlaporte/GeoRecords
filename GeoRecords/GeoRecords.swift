import SwiftUI
import UserNotifications

// A simple deep-link manager.
class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()
    @Published var recordType: String? = nil
    @Published var navigateToStats = false
    @Published var pendingBackupURL: URL? = nil  // For incoming backup files
    @Published var navigateToRegions: String? = nil  // "states", "countries", or "continents"
    @Published var navigateToRecordsTimeFrame: TimeFrame? = nil
    @Published var navigateToRecordsTab = false  // Plain tab switch, no timeframe change
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

            // Also extract timeFrame if present (for monthly/yearly records)
            if let timeFrameRaw = userInfo["timeFrame"] as? String,
               let timeFrame = TimeFrame(rawValue: timeFrameRaw) {
                DeepLinkManager.shared.navigateToRecordsTimeFrame = timeFrame
                debugLog("DeepLink: timeFrame set to \(timeFrame)")
            }
        }

        // Handle page deep links (summary notifications, catch-up digest)
        if let deepLink = userInfo["deepLink"] as? String {
            Task { @MainActor in
                switch deepLink {
                case "stats":
                    DeepLinkManager.shared.navigateToStats = true
                case "regions":
                    DeepLinkManager.shared.navigateToRegions = "countries"
                case "records":
                    DeepLinkManager.shared.navigateToRecordsTab = true
                default:
                    break
                }
                debugLog("DeepLink: navigating to \(deepLink)")
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

        // Start monitoring photo library for new photos (catches extreme locations from camera)
        PhotoLocationMonitor.shared.startMonitoring()

        // Warm the region-boundary data (~36MB of GeoJSON) off the main thread so the
        // first Maps view or photo scan doesn't pay the parse as a main-thread hang
        Task.detached(priority: .utility) {
            RegionLookupService.shared.loadBoundaries()
        }

        // Startup maintenance tasks
        Task {
            try? await Task.sleep(nanoseconds: standardDelayNanos)  // Wait 2 seconds after launch

            // Perform data cleanup (duplicates, at-home records, etc.)
            await MainActor.run {
                let cleaned = RecordHistoryManager.shared.performDataCleanup()
                if cleaned > 0 {
                    debugLog("🧹 Startup cleanup: cleaned \(cleaned) record(s)")
                }
            }

            // Catch up on photos taken while the app wasn't running
            // (the live photo monitor only sees changes while the app is alive)
            await PhotoLocationMonitor.shared.performCatchUpScan()

            // Start background geocoding for any records missing location names
            await BackgroundGeocoder.shared.geocodeMissingLocations()

            // Generate thumbnails for existing records that don't have cached thumbnails
            // This ensures widget photos work for records imported before this feature
            await ThumbnailCache.shared.generateMissingThumbnails()

            // Generate map snapshots for the region map widget
            // Delay longer to avoid conflicts with map views during navigation
            try? await Task.sleep(nanoseconds: mapGenerationDelayNanos)  // Avoid conflicts with map views
            await WidgetMapGenerator.shared.generateAllMaps()
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

        // Parse query parameters
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        switch url.host {
        case "records":
            // Navigate to Records tab with optional timeframe
            if let timeFrameParam = params["timeframe"],
               let timeFrame = TimeFrame(deepLinkParam: timeFrameParam) {
                DeepLinkManager.shared.navigateToRecordsTimeFrame = timeFrame
                debugLog("Deep link: Opening records tab with timeframe \(timeFrame)")
            } else {
                debugLog("Deep link: Opening records tab from widget")
            }
        case "regions":
            // Navigate to Regions tab with optional section
            if let section = params["section"] {
                DeepLinkManager.shared.navigateToRegions = section
                debugLog("Deep link: Opening regions tab with section \(section)")
            } else {
                DeepLinkManager.shared.navigateToRegions = "states"  // Default to states
                debugLog("Deep link: Opening regions tab from widget")
            }
        case "stats":
            // Navigate to Stats tab
            DeepLinkManager.shared.navigateToStats = true
            debugLog("Deep link: Opening stats tab from widget")
        default:
            break
        }
    }
}
