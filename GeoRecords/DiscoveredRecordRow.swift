import SwiftUI
import Photos
import CoreLocation

/// Row view for displaying a discovered record in the import preview list
struct DiscoveredRecordRow: View {
    @Binding var record: DiscoveredRecord
    let unitSystem: UnitSystem
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button(action: {
                record.selected.toggle()
            }) {
                Image(systemName: record.selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(record.selected ? .blue : .gray)
                    .font(.title2)
            }
            .buttonStyle(PlainButtonStyle())

            // Thumbnail
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .overlay {
                        ProgressView()
                    }
            }

            // Record info
            VStack(alignment: .leading, spacing: 4) {
                Text(record.recordType)
                    .font(.headline)

                Text(formatValue())
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(formatDate(record.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .onAppear {
            loadThumbnail()
        }
    }

    private func formatValue() -> String {
        return FormatUtils.formatDiscoveredRecordValue(
            recordType: record.recordType,
            value: record.value,
            altitude: record.altitude,
            unitSystem: unitSystem,
            coordinatePrecision: 4
        )
    }

    private func formatDate(_ date: Date) -> String {
        return mediumDateFormatter.string(from: date)
    }

    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: record.photoAsset,
            targetSize: CGSize(width: 120, height: 120),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            self.thumbnail = image
        }
    }
}
