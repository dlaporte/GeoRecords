import SwiftUI
import Photos

// MARK: - Wizard Progress Indicator

/// Progress indicator showing the wizard steps
struct WizardProgressIndicator: View {
    let currentStep: ImportWizardStep

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    WizardStepItem(step: .allTime, currentStep: currentStep)
                        .id(ImportWizardStep.allTime)
                    WizardStepConnector(isCompleted: currentStep.rawValue > 0)
                    WizardStepItem(step: .yearly, currentStep: currentStep)
                        .id(ImportWizardStep.yearly)
                    WizardStepConnector(isCompleted: currentStep.rawValue > 1)
                    WizardStepItem(step: .monthly, currentStep: currentStep)
                        .id(ImportWizardStep.monthly)
                    WizardStepConnector(isCompleted: currentStep.rawValue > 2)
                    WizardStepItem(step: .states, currentStep: currentStep)
                        .id(ImportWizardStep.states)
                    WizardStepConnector(isCompleted: currentStep.rawValue > 3)
                    WizardStepItem(step: .countries, currentStep: currentStep)
                        .id(ImportWizardStep.countries)
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: currentStep) { _, newStep in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newStep, anchor: .center)
                }
            }
            .onAppear {
                // Center on current step when view appears
                proxy.scrollTo(currentStep, anchor: .center)
            }
        }
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
    }
}

/// Individual step item in the progress indicator
private struct WizardStepItem: View {
    let step: ImportWizardStep
    let currentStep: ImportWizardStep

    private var isActive: Bool { step == currentStep }
    private var isCompleted: Bool { step.rawValue < currentStep.rawValue }

    private var circleColor: Color {
        if isActive { return .blue }
        if isCompleted { return .green }
        return Color.gray.opacity(0.3)
    }

    private var textColor: Color {
        if isActive { return .primary }
        if isCompleted { return .secondary }
        return .secondary.opacity(0.6)
    }

    var body: some View {
        HStack(spacing: 6) {
            stepCircle
            stepTitle
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(stepBackground)
    }

    private var stepCircle: some View {
        ZStack {
            Circle()
                .fill(circleColor)
                .frame(width: 24, height: 24)

            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text("\(step.rawValue + 1)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive ? .white : .secondary)
            }
        }
    }

    private var stepTitle: some View {
        Text(step.shortTitle)
            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
            .foregroundColor(textColor)
    }

    private var stepBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(isActive ? Color.blue.opacity(0.12) : Color.clear)
    }
}

/// Connector line between steps
private struct WizardStepConnector: View {
    let isCompleted: Bool

    var body: some View {
        Rectangle()
            .fill(isCompleted ? Color.green.opacity(0.5) : Color.gray.opacity(0.2))
            .frame(width: 16, height: 2)
    }
}

// MARK: - Wizard Navigation Bar

/// Bottom navigation bar with Back/Next buttons
struct WizardNavigationBar: View {
    let currentStep: ImportWizardStep
    let onBack: () -> Void
    let onNext: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Back button
            if let previousStep = currentStep.previousStep {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline)
                        Text("Back: \(previousStep.shortTitle)")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.gray.opacity(0.15))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
                }
            } else {
                Spacer()
                    .frame(maxWidth: .infinity)
            }

            // Next/Finish button
            if let nextStep = currentStep.nextStep {
                Button(action: onNext) {
                    HStack(spacing: 4) {
                        Text("Next: \(nextStep.shortTitle)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.right")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            } else {
                Button(action: onFinish) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                        Text("Import Records")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - Wizard Record Card

/// Compact card for displaying a record with swipeable photo alternatives
/// Uses toggle switch to include/skip record
/// Auto-loads more photos as user swipes near the end
struct WizardRecordCard: View {
    let recordType: String
    let candidates: [DiscoveredRecord]
    let selectedIndex: Int
    let unitSystem: UnitSystem
    let onSelect: (Int) -> Void

    /// Whether this is a new record (no existing record for this timeframe)
    var isNew: Bool = false

    /// Called when user modifies the selection (swipes to a different photo)
    var onModified: (() -> Void)? = nil

    @State private var currentPhotoIndex: Int
    @State private var isIncluded: Bool
    @State private var loadedImages: [String: UIImage] = [:]
    @State private var visibleCount: Int

    /// Whether there are more photos available to load
    private var hasMorePhotos: Bool {
        candidates.count > visibleCount
    }

    /// Index value that represents "Skip" - uses total candidates count for consistent storage
    private var skipIndex: Int {
        candidates.count
    }

    init(recordType: String, candidates: [DiscoveredRecord], selectedIndex: Int, unitSystem: UnitSystem, onSelect: @escaping (Int) -> Void, isNew: Bool = false, onModified: (() -> Void)? = nil) {
        self.recordType = recordType
        self.candidates = candidates
        self.selectedIndex = selectedIndex
        self.unitSystem = unitSystem
        self.onSelect = onSelect
        self.isNew = isNew
        self.onModified = onModified

        // Determine initial visible count - if selected index is beyond initial batch, expand to include it
        let initialVisible: Int
        if selectedIndex >= wizardMaxCandidatesPerType && selectedIndex < candidates.count {
            // User has a selection beyond initial batch, expand visible count
            initialVisible = ((selectedIndex / wizardMaxCandidatesPerType) + 1) * wizardMaxCandidatesPerType
        } else {
            initialVisible = wizardMaxCandidatesPerType
        }
        self._visibleCount = State(initialValue: min(initialVisible, candidates.count))

        // Initialize photo index and included state
        let isSkipped = selectedIndex >= candidates.count
        self._isIncluded = State(initialValue: !isSkipped)
        self._currentPhotoIndex = State(initialValue: isSkipped ? 0 : selectedIndex)
    }

    private var currentRecord: DiscoveredRecord? {
        guard currentPhotoIndex >= 0, currentPhotoIndex < candidates.count else { return nil }
        return candidates[currentPhotoIndex]
    }

    private var recordColor: Color {
        isIncluded ? FormatUtils.colorForRecordType(recordType) : .gray
    }

    var body: some View {
        VStack(spacing: 6) {
            // Photo carousel with toggle
            ZStack(alignment: .topTrailing) {
                TabView(selection: $currentPhotoIndex) {
                    ForEach(Array(candidates.prefix(visibleCount).enumerated()), id: \.element.id) { index, record in
                        WizardPhotoThumbnail(
                            asset: record.photoAsset,
                            loadedImage: loadedImages[record.photoAsset.localIdentifier],
                            onImageLoaded: { image in
                                loadedImages[record.photoAsset.localIdentifier] = image
                            }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 90)
                .cornerRadius(10)
                .onChange(of: currentPhotoIndex) { _, newIndex in
                    handleIndexChange(newIndex)
                }

                // Include toggle overlay
                Toggle("", isOn: $isIncluded)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .padding(4)
                    .onChange(of: isIncluded) { _, included in
                        handleToggleChange(included)
                    }
            }

            // Record info - fixed height to prevent layout shifts
            VStack(spacing: 2) {
                // Icon and name row
                HStack(spacing: 4) {
                    Image(systemName: FormatUtils.iconForRecordType(recordType))
                        .font(.system(size: 12))
                        .foregroundColor(recordColor)

                    Text(FormatUtils.shortName(for: recordType))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isIncluded ? .primary : .secondary)
                        .lineLimit(1)

                    // NEW badge for records that don't exist yet
                    if isNew {
                        Text("NEW")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.green)
                            .cornerRadius(4)
                    }

                    Spacer()
                }

                // Value and location
                if let record = currentRecord {
                    Text(FormatUtils.formatDiscoveredRecordValue(
                        recordType: recordType,
                        value: record.value,
                        altitude: record.altitude,
                        unitSystem: unitSystem,
                        coordinatePrecision: 4
                    ))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(recordColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Location name (always show row to maintain consistent height)
                    Text(record.locationName ?? " ")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 48)  // Fixed height for consistency
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .opacity(isIncluded ? 1.0 : 0.6)
        .onChange(of: selectedIndex) { _, newIndex in
            // Sync if external selection changes
            let isSkipped = newIndex >= skipIndex
            if isIncluded != !isSkipped {
                isIncluded = !isSkipped
            }
            if !isSkipped && currentPhotoIndex != newIndex {
                currentPhotoIndex = newIndex
            }
        }
        .onAppear {
            preloadImages()
        }
    }

    /// Handle photo index change
    private func handleIndexChange(_ newIndex: Int) {
        // Auto-load more photos when approaching the end
        if hasMorePhotos && newIndex >= visibleCount - 2 {
            loadMorePhotos()
        }

        // Update selection if included
        if isIncluded {
            onSelect(newIndex)
            if onModified != nil {
                debugLog("📝 WizardRecordCard: calling onModified for \(recordType), newIndex=\(newIndex)")
                onModified?()
            }
        }
    }

    /// Handle toggle change
    private func handleToggleChange(_ included: Bool) {
        if included {
            // Include: select current photo
            onSelect(currentPhotoIndex)
        } else {
            // Exclude: select skip index
            onSelect(skipIndex)
        }
        onModified?()
    }

    /// Auto-load more photos when user swipes near the end
    private func loadMorePhotos() {
        let previousCount = visibleCount
        visibleCount = min(visibleCount + wizardMaxCandidatesPerType, candidates.count)

        // Preload images for newly visible photos
        for candidate in candidates[previousCount..<min(visibleCount, candidates.count)] {
            loadImage(for: candidate)
        }
    }

    private func preloadImages() {
        for candidate in candidates.prefix(5) {
            loadImage(for: candidate)
        }
    }

    private func loadImage(for record: DiscoveredRecord) {
        let identifier = record.photoAsset.localIdentifier
        guard loadedImages[identifier] == nil else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: record.photoAsset,
            targetSize: CGSize(width: 200, height: 200),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            if let image = image {
                DispatchQueue.main.async {
                    self.loadedImages[identifier] = image
                }
            }
        }
    }
}

// MARK: - Wizard Photo Thumbnail

/// Thumbnail view for a photo asset in the import wizard
struct WizardPhotoThumbnail: View {
    let asset: PHAsset
    let loadedImage: UIImage?
    let onImageLoaded: (UIImage) -> Void

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if let img = image ?? loadedImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.8)
                        )
                }

                // Favorite heart indicator
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .padding(4)
                }
            }
        }
        .onAppear {
            if loadedImage == nil && image == nil {
                loadThumbnail()
            }
        }
    }

    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 200, height: 200),
            contentMode: .aspectFill,
            options: options
        ) { loadedImg, _ in
            if let loadedImg = loadedImg {
                DispatchQueue.main.async {
                    self.image = loadedImg
                    self.onImageLoaded(loadedImg)
                }
            }
        }
    }
}

// MARK: - Empty State View

/// Empty state view for wizard steps with no records
struct WizardEmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Section Header

/// Header view for year/month sections
struct WizardSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 8)
    }
}
