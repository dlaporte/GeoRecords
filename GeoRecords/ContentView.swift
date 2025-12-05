import SwiftUI

struct ContentView: View {
    @EnvironmentObject var deepLinkManager: DeepLinkManager
    @EnvironmentObject var recordManager: RecordManager
    @EnvironmentObject var recordHistoryManager: RecordHistoryManager
    @EnvironmentObject var persistenceController: PersistenceController
    @EnvironmentObject var settings: SettingsManager
    @State private var showDatabaseError = false
    @State private var showSetupWizard = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            RecordsView()
                .tabItem {
                    Label("Records", systemImage: "doc.text")
                }
                .tag(0)
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(1)
            StatisticsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }
                .tag(2)
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
        .onAppear {
            // Check if setup needs to be shown
            if !settings.hasCompletedSetup {
                showSetupWizard = true
            }

            // Check for database errors on app launch
            if PersistenceController.shared.loadError != nil {
                showDatabaseError = true
            }
        }
        .onChange(of: deepLinkManager.navigateToStats) { _, shouldNavigate in
            if shouldNavigate {
                selectedTab = 2  // Navigate to Stats tab
                deepLinkManager.navigateToStats = false  // Reset flag
            }
        }
        .fullScreenCover(isPresented: $showSetupWizard) {
            SetupWizardView()
                .environmentObject(settings)
        }
        .alert(isPresented: $showDatabaseError) {
            Alert(
                title: Text("Database Error"),
                message: Text("The app encountered a problem with its database. Your data may have been reset."),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $recordHistoryManager.showError) {
            Alert(
                title: Text("Error"),
                message: Text(recordHistoryManager.errorMessage ?? "An unknown error occurred"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $persistenceController.showDatabaseRecoveryAlert) {
            Alert(
                title: Text("Database Corrupted"),
                message: Text("The app's database is corrupted and cannot be loaded. Would you like to reset it? This will delete all your records permanently."),
                primaryButton: .destructive(Text("Reset Database")) {
                    if let storeURL = persistenceController.container.persistentStoreDescriptions.first?.url {
                        persistenceController.attemptDatabaseRecovery(storeURL: storeURL)
                    }
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
        .sheet(isPresented: $recordManager.showPhotoPrompt) {
            if let pending = recordManager.pendingRecordForPhoto {
                PhotoPicker(
                    recordType: pending.type,
                    onPhotoSelected: { photoData in
                        recordManager.attachPhotoToRecord(recordType: pending.type, photoData: photoData)
                    },
                    onDismiss: {
                        recordManager.showPhotoPrompt = false
                        recordManager.pendingRecordForPhoto = nil
                    }
                )
            }
        }
    }
}
