import SwiftUI
import Photos
import MapKit
import UserNotifications
import CoreLocation

struct SetupWizardView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var locationManager: LocationManager
    @StateObject private var photoScanner = PhotoLibraryScanner()
    @Environment(\.dismiss) var dismiss

    @State private var currentStep = 0
    @State private var selectedUnitSystem: UnitSystem = .imperial
    @State private var homeCoordinate: CLLocationCoordinate2D?
    @State private var notificationsEnabled = true
    @State private var summaryNotificationsEnabled = true
    @State private var photoPromptsEnabled = true
    @State private var wantPhotoImport = true
    @State private var showPermissionAlert = false
    @State private var showImportPreview = false

    let totalSteps = 6

    // Check if Next button should be enabled
    private var isNextButtonEnabled: Bool {
        // Step 2 is home location - require it to be set
        if currentStep == 2 {
            return homeCoordinate != nil
        }
        return true
    }

    // Calculate visible steps for progress indicator
    private var visibleSteps: [Int] {
        if notificationsEnabled {
            // All steps visible: 0, 1, 2, 3, 4, 5, 6
            return Array(0...6)
        } else {
            // Skip steps 4 and 5: 0, 1, 2, 3, 6
            return [0, 1, 2, 3, 6]
        }
    }

    // Map current step to progress index
    private var progressIndex: Int {
        visibleSteps.firstIndex(of: currentStep) ?? 0
    }

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress indicator (hide when showing import preview)
                if !showImportPreview {
                    HStack(spacing: 8) {
                    ForEach(0..<visibleSteps.count, id: \.self) { index in
                        Capsule()
                            .fill(index <= progressIndex ? Color.blue : Color.gray.opacity(0.3))
                            .frame(height: 4)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }

                // Content (hide when showing import preview)
                if !showImportPreview {
                    TabView(selection: $currentStep) {
                    // Step 0: Welcome
                    WelcomeStepView()
                        .tag(0)

                    // Step 1: Units
                    UnitsStepView(selectedUnitSystem: $selectedUnitSystem)
                        .tag(1)

                    // Step 2: Home Location
                    HomeLocationStepView(homeCoordinate: $homeCoordinate)
                        .tag(2)

                    // Step 3: Record Notifications
                    NotificationsStepView(
                        notificationsEnabled: $notificationsEnabled
                    )
                    .tag(3)

                    // Step 4: Summary Notifications
                    SummaryNotificationsStepView(
                        summaryNotificationsEnabled: $summaryNotificationsEnabled
                    )
                    .tag(4)

                    // Step 5: Photo Prompts
                    PhotoPromptsStepView(
                        photoPromptsEnabled: $photoPromptsEnabled
                    )
                    .tag(5)

                    // Step 6: Photo Import
                    PhotoImportStepView(
                        wantPhotoImport: $wantPhotoImport,
                        photoScanner: photoScanner,
                        showPermissionAlert: $showPermissionAlert
                    )
                    .tag(6)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut, value: currentStep)
                }

                // Navigation buttons (hide when showing import preview)
                if !showImportPreview {
                    HStack(spacing: 20) {
                    if currentStep > 0 {
                        Button(action: {
                            withAnimation {
                                currentStep = getPreviousStep()
                            }
                        }) {
                            HStack {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                        }
                    }

                    Button(action: {
                        if currentStep < totalSteps - 1 {
                            // If leaving welcome screen, request location permissions
                            if currentStep == 0 {
                                locationManager.requestLocationAuthorization()
                            }

                            // If leaving record notifications step
                            if currentStep == 3 {
                                if notificationsEnabled {
                                    requestNotificationPermissions()
                                } else {
                                    // Disable sub-notification types if main notifications are off
                                    summaryNotificationsEnabled = false
                                    photoPromptsEnabled = false
                                }
                            }

                            withAnimation {
                                currentStep = getNextStep()
                            }
                        } else {
                            completeSetup()
                        }
                    }) {
                        HStack {
                            Text(currentStep < totalSteps - 1 ? "Next" : "Get Started")
                            if currentStep < totalSteps - 1 {
                                Image(systemName: "chevron.right")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isNextButtonEnabled ? Color.blue : Color.gray.opacity(0.3))
                        .foregroundColor(isNextButtonEnabled ? .white : .gray)
                        .cornerRadius(12)
                    }
                    .disabled(!isNextButtonEnabled)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            }
        }
        .interactiveDismissDisabled()
        .alert("Photo Access Required", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Skip", role: .cancel) {
                wantPhotoImport = false
                dismiss()
            }
        } message: {
            Text("Please grant photo library access in Settings to import records from your photos.")
        }
        .fullScreenCover(isPresented: $showImportPreview, onDismiss: {
            // When import is complete, dismiss wizard
            dismiss()
        }) {
            ImportPreviewView()
                .environmentObject(photoScanner)
                .environmentObject(settings)
                .interactiveDismissDisabled()  // Prevent accidental dismissal
        }
    }

    // Helper to get next step, skipping notification detail steps if notifications are disabled
    private func getNextStep() -> Int {
        // Step 3 is record notifications
        // Steps 4-5 are summary notifications and photo prompts (skip if notifications disabled)
        // Step 6 is photo import

        if currentStep == 3 && !notificationsEnabled {
            // Skip steps 4 and 5, go directly to 6
            return 6
        }

        return currentStep + 1
    }

    // Helper to get previous step, skipping notification detail steps if they were skipped
    private func getPreviousStep() -> Int {
        // If coming back from photo import (step 6) and notifications are off, skip back to step 3
        if currentStep == 6 && !notificationsEnabled {
            return 3
        }

        return currentStep - 1
    }

    private func completeSetup() {
        // Save settings
        settings.unitSystem = selectedUnitSystem
        // homeCoordinate already saved directly to settings during selection
        // Enable yearly, all-time, and new region notifications (not monthly - too noisy)
        settings.notifyOnYearlyRecords = notificationsEnabled
        settings.notifyOnAllTimeRecords = notificationsEnabled
        settings.notifyOnNewRegion = notificationsEnabled
        settings.summaryNotificationsEnabled = summaryNotificationsEnabled
        settings.photoPromptsEnabled = photoPromptsEnabled
        // Enable inactivity reminder if user granted notification permission
        settings.inactivityReminderEnabled = notificationsEnabled
        settings.hasCompletedSetup = true
        settings.saveSettings()

        // Create region records for the home location (state, country, continent)
        RegionTrackingManager.shared.addHomeRegionRecords()

        // Schedule inactivity reminder if enabled
        if notificationsEnabled {
            Task { @MainActor in
                LocationManager.shared.scheduleInactivityReminder()
            }
        }

        // Notification permissions already requested when leaving step 3

        // If user wants photo import, trigger it
        if wantPhotoImport {
            checkPhotoPermissionAndImport()
        } else {
            dismiss()
        }
    }

    private func checkPhotoPermissionAndImport() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .authorized, .limited:
            // Show ImportPreviewView immediately so scanning UI appears full-screen
            DispatchQueue.main.async {
                self.showImportPreview = true
                // Start scanning after view appears - ImportPreviewView will display progress
                Task {
                    // Small delay to ensure view transition completes
                    try? await Task.sleep(nanoseconds: briefPauseNanos) // 0.1 seconds
                    await self.photoScanner.scanPhotoLibrary(homeCoordinate: self.settings.homeCoordinate)
                }
            }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                Task { @MainActor in
                    if newStatus == .authorized || newStatus == .limited {
                        self.showImportPreview = true
                        Task {
                            // Small delay to ensure view transition completes
                            try? await Task.sleep(nanoseconds: briefPauseNanos) // 0.1 seconds
                            await self.photoScanner.scanPhotoLibrary(homeCoordinate: self.settings.homeCoordinate)
                        }
                    } else {
                        dismiss()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionAlert = true
        @unknown default:
            dismiss()
        }
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            debugLog("Notification permissions granted: \(granted)")
        }
    }
}
