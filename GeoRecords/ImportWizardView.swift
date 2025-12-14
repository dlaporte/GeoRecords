import SwiftUI

// MARK: - Import Wizard View

/// Main wizard container for photo import flow
struct ImportWizardView: View {
    @ObservedObject var scanner: PhotoLibraryScanner
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.dismiss) var dismiss

    let onImport: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Progress indicator
                WizardProgressIndicator(currentStep: scanner.currentWizardStep)

                // Step content (no swipe - buttons only)
                Group {
                    switch scanner.currentWizardStep {
                    case .allTime:
                        AllTimeStepView(scanner: scanner)
                    case .yearly:
                        YearlyStepView(scanner: scanner)
                    case .monthly:
                        MonthlyStepView(scanner: scanner)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: scanner.currentWizardStep)

                // Navigation buttons
                WizardNavigationBar(
                    currentStep: scanner.currentWizardStep,
                    onBack: goToPreviousStep,
                    onNext: goToNextStep,
                    onFinish: finishWizard
                )
            }
            .disabled(scanner.isImporting)

            // Import progress overlay
            if scanner.isImporting {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)

                    Text("Importing Records...")
                        .font(.headline)

                    if scanner.importProgress.total > 0 {
                        Text("\(scanner.importProgress.current) of \(scanner.importProgress.total)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(30)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(UIColor.systemBackground))
                )
                .shadow(radius: 10)
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private func goToPreviousStep() {
        if let previousStep = scanner.currentWizardStep.previousStep {
            scanner.currentWizardStep = previousStep
        }
    }

    private func goToNextStep() {
        if let nextStep = scanner.currentWizardStep.nextStep {
            scanner.currentWizardStep = nextStep
        }
    }

    private func finishWizard() {
        scanner.buildConfirmedRecordsFromSelections()
        onImport()
    }
}

// MARK: - All-Time Step View

/// Step 1: All-time records selection
struct AllTimeStepView: View {
    @ObservedObject var scanner: PhotoLibraryScanner
    @EnvironmentObject var settings: SettingsManager

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Select your all-time best records")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)

                if scanner.allTimeCandidates.isEmpty {
                    WizardEmptyStateView(
                        title: "No All-Time Records",
                        message: "No photos found that would set all-time records."
                    )
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(RecordType.allCases, id: \.rawValue) { recordType in
                            if let candidates = scanner.allTimeCandidates[recordType.rawValue],
                               !candidates.isEmpty {
                                WizardRecordCard(
                                    recordType: recordType.rawValue,
                                    candidates: candidates,
                                    selectedIndex: scanner.wizardSelections.allTime[recordType.rawValue] ?? 0,
                                    unitSystem: settings.unitSystem,
                                    onSelect: { index in
                                        scanner.updateAllTimeSelection(recordType: recordType.rawValue, index: index)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Yearly Step View

/// Step 2: Yearly records selection
struct YearlyStepView: View {
    @ObservedObject var scanner: PhotoLibraryScanner
    @EnvironmentObject var settings: SettingsManager

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Select records for each year")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)

                if scanner.yearlyBuckets.isEmpty {
                    WizardEmptyStateView(
                        title: "No Yearly Records",
                        message: "No photos found for yearly records."
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(scanner.yearlyBuckets) { bucket in
                            YearSectionView(
                                bucket: bucket,
                                columns: columns,
                                scanner: scanner,
                                unitSystem: settings.unitSystem
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }
}

/// Section view for a single year
struct YearSectionView: View {
    let bucket: YearBucket
    let columns: [GridItem]
    @ObservedObject var scanner: PhotoLibraryScanner
    let unitSystem: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WizardSectionHeader(title: "\(bucket.id)")

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(bucket.availableRecordTypes, id: \.self) { recordType in
                    if let candidates = bucket.records[recordType], !candidates.isEmpty {
                        WizardRecordCard(
                            recordType: recordType,
                            candidates: candidates,
                            selectedIndex: scanner.wizardSelections.yearly[bucket.id]?[recordType] ?? 0,
                            unitSystem: unitSystem,
                            onSelect: { index in
                                scanner.updateYearlySelection(year: bucket.id, recordType: recordType, index: index)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Monthly Step View

/// Step 3: Monthly records selection (current year only)
struct MonthlyStepView: View {
    @ObservedObject var scanner: PhotoLibraryScanner
    @EnvironmentObject var settings: SettingsManager

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Select records for each month of \(currentYear)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)

                if scanner.monthlyBuckets.isEmpty {
                    WizardEmptyStateView(
                        title: "No Monthly Records",
                        message: "No photos found for this year's monthly records."
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(scanner.monthlyBuckets) { bucket in
                            MonthSectionView(
                                bucket: bucket,
                                columns: columns,
                                scanner: scanner,
                                unitSystem: settings.unitSystem
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
}

/// Section view for a single month
struct MonthSectionView: View {
    let bucket: MonthBucket
    let columns: [GridItem]
    @ObservedObject var scanner: PhotoLibraryScanner
    let unitSystem: UnitSystem

    private var monthKey: String {
        WizardSelection.monthKey(year: bucket.year, month: bucket.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WizardSectionHeader(title: bucket.displayName)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(bucket.availableRecordTypes, id: \.self) { recordType in
                    if let candidates = bucket.records[recordType], !candidates.isEmpty {
                        WizardRecordCard(
                            recordType: recordType,
                            candidates: candidates,
                            selectedIndex: scanner.wizardSelections.monthly[monthKey]?[recordType] ?? 0,
                            unitSystem: unitSystem,
                            onSelect: { index in
                                scanner.updateMonthlySelection(year: bucket.year, month: bucket.id, recordType: recordType, index: index)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}
