//
//  RecordPhotoView.swift
//  GeoRecords
//
//  A record's photo at its own aspect ratio, inside the content margins with the
//  card radius, with the change-photo and full-screen buttons. The 220 pt fill strip
//  it replaces cropped every photo to a sliver on anything wider than a phone.
//

import SwiftUI
import PhotosUI

/// How the photo takes the room it is given
enum PhotoFit: Equatable {
    /// The content width, capped at a height (nil: no cap)
    case fitWidth(maxHeight: CGFloat?)
    /// The room's height, capped at a width (a panel with the rows beside it)
    case fitHeight(maxWidth: CGFloat)

    var maxWidth: CGFloat? {
        if case .fitHeight(let maxWidth) = self { return maxWidth }
        return .infinity
    }

    /// A cap of zero (the host not yet measured) is no cap, not a 120 pt photo
    var maxHeight: CGFloat? {
        switch self {
        case .fitWidth(let maxHeight): return maxHeight.flatMap { $0 > 0 ? max($0, 120) : nil } ?? .infinity
        case .fitHeight: return .infinity
        }
    }
}

struct RecordPhotoView: View {
    let image: UIImage
    let fit: PhotoFit
    let canChange: Bool
    @Binding var selection: PhotosPickerItem?
    @Binding var showFullScreen: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: { showFullScreen = true }) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: fit.maxWidth, maxHeight: fit.maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                if canChange {
                    PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "photo.badge.arrow.down")
                            .font(.caption)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                }
                Button(action: { showFullScreen = true }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
            }
            .padding(8)
        }
    }
}
