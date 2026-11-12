//
//  RecordPhotoView.swift
//  GeoRecords
//
//  A record's photo inside the content margins with the card radius, with the
//  change-photo and full-screen buttons. Landscape photos keep their own aspect
//  ratio; anything taller than 4:3 is cropped to 4:3 (the full-screen viewer keeps
//  the whole photo), so a portrait phone photo never stands as a narrow strip with
//  blank space either side, nor runs 600 pt tall in a narrow column. The border is
//  drawn around the photo itself, not around the room it was offered.
//

import SwiftUI
import PhotosUI

/// How the photo takes the room it is given
enum PhotoFit: Equatable {
    /// The content width, capped at a height (nil: no cap)
    case fitWidth(maxHeight: CGFloat?)
    /// The room's height, capped at a width (a panel with the rows beside it)
    case fitHeight(maxWidth: CGFloat)

    /// Photos are never drawn taller than 4:3
    static let tallestAspect: CGFloat = 4 / 3

    /// The width-to-height ratio the photo is drawn at: its own, or 4:3 when it is taller
    static func displayAspect(forImageSize size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return tallestAspect }
        return max(size.width / size.height, tallestAspect)
    }

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
        // The box is sized by its aspect ratio inside the room offered; the clip,
        // the border and the buttons then follow the box, and the room stays invisible
        Color.clear
            .aspectRatio(PhotoFit.displayAspect(forImageSize: image.size), contentMode: .fit)
            .overlay {
                Button(action: { showFullScreen = true }) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .buttonStyle(.plain)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
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
            .frame(maxWidth: fit.maxWidth, maxHeight: fit.maxHeight, alignment: .topLeading)
    }
}
