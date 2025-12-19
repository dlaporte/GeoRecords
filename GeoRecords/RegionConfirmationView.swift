import SwiftUI
import Photos

// MARK: - Region Confirmation View

/// View for confirming discovered regions during photo import wizard
/// Shows each region with a swipeable photo carousel and confirmation toggle
struct RegionConfirmationView: View {
    let regionType: RegionType
    @Binding var regions: [DiscoveredRegion]
    let onNext: () -> Void
    let onBack: () -> Void

    @State private var loadedImages: [String: UIImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            if regions.isEmpty {
                emptyState
            } else {
                // Regions list with photo carousels
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach($regions) { $region in
                            RegionCard(
                                region: $region,
                                loadedImages: $loadedImages
                            )
                        }
                    }
                    .padding()
                }

                // Select All / Deselect All buttons
                selectionButtons
            }

            // Navigation
            navigationBar
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private var headerSection: some View {
        VStack(spacing: 4) {
            Text(regionType == .country ? "Did you visit these countries?" : "Did you visit these states?")
                .font(.headline)

            Text("Uncheck regions you didn't actually visit (e.g., shared photos from family)")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color(UIColor.systemBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: regionType == .country ? "globe" : "map")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No \(regionType.pluralName.lowercased()) found in your photos")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionButtons: some View {
        HStack(spacing: 12) {
            Button("Select All") {
                for i in regions.indices {
                    regions[i].confirmed = true
                }
            }
            .buttonStyle(.bordered)

            Button("Deselect All") {
                for i in regions.indices {
                    regions[i].confirmed = false
                }
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
        }
        .padding()
        .background(Color(UIColor.systemBackground))
    }

    private var navigationBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }

            Spacer()

            Text("\(regions.filter { $0.confirmed }.count) of \(regions.count) selected")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: onNext) {
                HStack(spacing: 4) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
            }
            .fontWeight(.semibold)
        }
        .padding()
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - Region Card

/// Card for a single region with photo carousel and confirmation toggle
struct RegionCard: View {
    @Binding var region: DiscoveredRegion
    @Binding var loadedImages: [String: UIImage]

    @State private var currentPhotoIndex: Int = 0

    private let maxPhotosToShow = 10

    var body: some View {
        VStack(spacing: 0) {
            // Header with name and toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(region.regionName)
                        .font(.headline)

                    Text("\(region.photoCount) photo\(region.photoCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: $region.confirmed)
                    .labelsHidden()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            // Photo carousel
            if !region.photoAssets.isEmpty {
                photoCarousel
            }
        }
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        .opacity(region.confirmed ? 1.0 : 0.6)
    }

    private var photoCarousel: some View {
        TabView(selection: $currentPhotoIndex) {
            ForEach(Array(region.photoAssets.prefix(maxPhotosToShow).enumerated()), id: \.element.localIdentifier) { index, asset in
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
        .tabViewStyle(.page(indexDisplayMode: region.photoAssets.count > 1 ? .automatic : .never))
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 12)
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
        ZStack {
            if let img = image ?? loadedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        ProgressView()
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task {
            if image == nil && loadedImage == nil {
                await loadImage()
            }
        }
    }

    private func loadImage() async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        let targetSize = CGSize(width: 400, height: 300)

        await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { result, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let result = result, !isDegraded {
                    Task { @MainActor in
                        self.image = result
                        onImageLoaded(result)
                    }
                    continuation.resume()
                } else if result == nil {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    RegionConfirmationView(
        regionType: .country,
        regions: .constant([]),
        onNext: {},
        onBack: {}
    )
}
