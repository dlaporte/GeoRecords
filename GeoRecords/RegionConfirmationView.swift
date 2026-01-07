import SwiftUI
import Photos

// MARK: - Region Confirmation View

/// View for confirming discovered regions during photo import wizard
/// Uses 2-column grid layout matching the record confirmation style
struct RegionConfirmationView: View {
    let regionType: RegionType
    @Binding var regions: [DiscoveredRegion]
    let onNext: () -> Void
    let onBack: () -> Void

    /// Whether this is the last step - shows "Import Records" instead of "Next"
    var isLastStep: Bool = false
    /// Title for the back button
    var backTitle: String = "Monthly"
    /// Title for the next button (ignored if isLastStep)
    var nextTitle: String = "States"

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    /// Indices of regions sorted alphabetically by name
    private var sortedRegionIndices: [Int] {
        regions.indices.sorted { regions[$0].regionName < regions[$1].regionName }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select \(regionType.pluralName.lowercased()) to import")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    if regions.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(sortedRegionIndices, id: \.self) { index in
                                RegionCard(region: $regions[index])
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 16)
            }

            // Navigation bar matching WizardNavigationBar style
            navigationBar
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: regionType == .country ? "globe" : "map")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No \(regionType.pluralName.lowercased()) found")
                .font(.headline)

            Text("No photos found for \(regionType.pluralName.lowercased()).")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline)
                    Text("Back: \(backTitle)")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.gray.opacity(0.15))
                .foregroundColor(.primary)
                .cornerRadius(10)
            }

            // Next/Finish button
            if isLastStep {
                Button(action: onNext) {
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
            } else {
                Button(action: onNext) {
                    HStack(spacing: 4) {
                        Text("Next: \(nextTitle)")
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
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - Region Card

/// Compact card for a region with swipeable photo carousel
/// Matches WizardRecordCard styling
struct RegionCard: View {
    @Binding var region: DiscoveredRegion

    @State private var loadedImages: [String: UIImage] = [:]
    @State private var visibleCount: Int

    init(region: Binding<DiscoveredRegion>) {
        self._region = region
        self._visibleCount = State(initialValue: min(wizardMaxCandidatesPerType, region.wrappedValue.photoAssets.count))
    }

    /// Whether there are more photos available to load
    private var hasMorePhotos: Bool {
        region.photoAssets.count > visibleCount
    }

    private var regionColor: Color {
        region.regionType == .country ? .blue : .orange
    }

    private var regionIcon: String {
        region.regionType == .country ? "globe.americas.fill" : "flag.fill"
    }

    var body: some View {
        VStack(spacing: 6) {
            // Photo carousel
            ZStack(alignment: .topTrailing) {
                TabView(selection: $region.selectedPhotoIndex) {
                    ForEach(Array(region.photoAssets.prefix(visibleCount).enumerated()), id: \.element.localIdentifier) { index, asset in
                        RegionPhotoThumbnail(
                            asset: asset,
                            loadedImage: loadedImages[asset.localIdentifier],
                            onImageLoaded: { image in
                                loadedImages[asset.localIdentifier] = image
                            }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 90)
                .cornerRadius(10)
                .onChange(of: region.selectedPhotoIndex) { _, newIndex in
                    // Auto-load more photos when approaching the end
                    if hasMorePhotos && newIndex >= visibleCount - 2 {
                        loadMorePhotos()
                    }
                }

                // Confirmation toggle overlay
                Toggle("", isOn: $region.confirmed)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .padding(4)
            }

            // Region info
            VStack(spacing: 2) {
                // Icon and name row
                HStack(spacing: 4) {
                    Image(systemName: regionIcon)
                        .font(.system(size: 12))
                        .foregroundColor(region.confirmed ? regionColor : .secondary)

                    Text(region.regionName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(region.confirmed ? .primary : .secondary)
                        .lineLimit(1)

                    Spacer()
                }

                // Photo count or date
                HStack {
                    if region.photoAssets.count > 1 {
                        Text("\(region.photoAssets.count) photos")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else if let date = region.selectedAsset?.creationDate {
                        Text(shortDateFormatter.string(from: date))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .frame(height: 36)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .opacity(region.confirmed ? 1.0 : 0.6)
        .onAppear {
            preloadImages()
        }
    }

    private func loadMorePhotos() {
        visibleCount = min(visibleCount + wizardMaxCandidatesPerType, region.photoAssets.count)
    }

    private func preloadImages() {
        for asset in region.photoAssets.prefix(5) {
            loadImage(for: asset)
        }
    }

    private func loadImage(for asset: PHAsset) {
        let identifier = asset.localIdentifier
        guard loadedImages[identifier] == nil else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: asset,
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

// MARK: - Region Photo Thumbnail

/// Photo thumbnail for region carousel
struct RegionPhotoThumbnail: View {
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

// MARK: - Date Formatter

private let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

// MARK: - Preview

#Preview {
    RegionConfirmationView(
        regionType: .country,
        regions: .constant([]),
        onNext: {},
        onBack: {},
        isLastStep: false,
        backTitle: "Monthly",
        nextTitle: "States"
    )
}
