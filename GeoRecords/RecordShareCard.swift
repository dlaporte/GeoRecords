//
//  RecordShareCard.swift
//  GeoRecords
//
//  A self-contained square card for sharing one record as an image. Unlike
//  RecordCardView it takes everything it needs as plain values (no environment,
//  no screen-based sizing, a photo already loaded), so it can be rendered
//  off-screen by ImageRenderer. Rendering happens only when the user shares.
//

import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

struct RecordShareCardView: View {
    let record: RecordDetail
    let unitSystem: UnitSystem
    let homeCoordinate: CLLocationCoordinate2D?
    let photo: UIImage?

    static let side: CGFloat = 540
    static let scale: CGFloat = 3

    private var color: Color { FormatUtils.colorForRecordType(record.recordType) }

    private var placeName: String? {
        guard let name = record.locationName, !name.isEmpty, name != unknownLocationString else { return nil }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.side, height: Self.side * 0.5)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: FormatUtils.iconForRecordType(record.recordType))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(color)
                    Text(record.recordType)
                        .font(.system(size: 26, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(record.timeFrame.recordLabel)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text(record.formattedValue(unitSystem: unitSystem))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let placeName {
                    Text(placeName)
                        .font(.system(size: 24, weight: .medium))
                        .lineLimit(2)
                }

                Text(record.timestamp.formatted(date: .long, time: .omitted))
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)

                Text(HomeFraming.text(for: record, home: homeCoordinate, unitSystem: unitSystem).value)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Text("GeoRecords")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
        }
        .frame(width: Self.side, height: Self.side)
        .background(Color(UIColor.systemBackground))
        .environment(\.colorScheme, .light)
    }

    /// Render the card to a bitmap (main actor: ImageRenderer requirement)
    @MainActor
    static func render(record: RecordDetail, unitSystem: UnitSystem,
                       homeCoordinate: CLLocationCoordinate2D?, photo: UIImage?) -> UIImage? {
        let renderer = ImageRenderer(content: RecordShareCardView(record: record, unitSystem: unitSystem,
                                                                  homeCoordinate: homeCoordinate, photo: photo))
        renderer.scale = scale
        return renderer.uiImage
    }
}

/// RecordDetail is all value types (UUID, Date, coordinate, strings, Data, enums)
extension RecordDetail: @unchecked Sendable {}

/// What the detail view's ShareLink hands to the share sheet. The PNG is produced
/// on export, so opening a record (or paging through many) renders nothing.
struct RecordShareItem: Transferable {
    let record: RecordDetail
    let unitSystem: UnitSystem
    let homeCoordinate: CLLocationCoordinate2D?

    enum ShareError: Error { case renderFailed }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await MainActor.run {
                let photo = item.record.photoData.flatMap(UIImage.init(data:))
                    ?? ThumbnailCache.shared.loadThumbnail(for: item.record.id)
                guard let image = RecordShareCardView.render(record: item.record, unitSystem: item.unitSystem,
                                                             homeCoordinate: item.homeCoordinate, photo: photo),
                      let data = image.pngData() else {
                    throw ShareError.renderFailed
                }
                return data
            }
        }
        .suggestedFileName { "GeoRecords \($0.record.recordType).png" }
    }
}
