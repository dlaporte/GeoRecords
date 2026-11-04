//
//  HostedRender.swift
//  GeoRecordsTests
//
//  Renders a SwiftUI view in a window of a given size and attaches the PNG to the
//  test result, for eyeballing layouts at sizes no simulator here can take (the
//  folded iPhone Duo, its inner display). Export with
//  `xcrun xcresulttool export attachments`.
//

import XCTest
import SwiftUI

extension XCTestCase {
    /// Hosts the view in a window of the given size and attaches its render
    @MainActor
    func attach<V: View>(_ view: V, size: CGSize, name: String) {
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []  // the window sits under the status bar; the page would lose 59 pt
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "render-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        XCTAssertGreaterThan(image.size.width, 0)
    }
}
