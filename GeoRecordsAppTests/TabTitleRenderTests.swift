//
//  TabTitleRenderTests.swift
//  GeoRecordsTests
//
//  Under the regular-width top tab bar, iPadOS puts a plain NavigationStack's large
//  title 14 pt lower than a NavigationSplitView column's (a tester saw Stats sunk
//  beside Regions and History). SingleColumnTab hosts Stats and Settings so their
//  titles line up with the split-view tabs'. This renders both constructs under a
//  tab bar and compares where the title ink starts; it only means something on an
//  iPad simulator (regular width), on an iPhone both are plain stacks.
//

import XCTest
import SwiftUI
@testable import GeoRecords

@MainActor
final class TabTitleRenderTests: XCTestCase {

    func testSingleColumnTabTitleLinesUpWithSplitViewTitle() throws {
        // Compact width collapses the split view to its sidebar; only an iPad hosts both as columns
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "needs regular width: run on an iPad simulator")
        let size = CGSize(width: 834, height: 400)
        let split = render(probe(splitView), size: size, name: "title-split-view")
        let single = render(probe(singleColumn), size: size, name: "title-single-column")
        XCTAssertEqual(titleTop(of: split), titleTop(of: single))
        XCTAssertNotNil(titleTop(of: split))
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List { Text("row") }.navigationTitle("Records")
        } detail: {
            Text("detail")
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var singleColumn: some View {
        SingleColumnTab {
            ScrollView { Text("content").padding(.vertical) }.navigationTitle("Statistics")
        }
    }

    private func probe<V: View>(_ view: V) -> some View {
        TabView {
            Tab("Probe", systemImage: "chart.bar.fill") { view }
            Tab("Other", systemImage: "gear") { Text("other") }
        }
    }

    /// The first row with dark pixels in the leading 300 pt below the tab bar row,
    /// in points; nil when nothing dark is there
    private func titleTop(of image: UIImage) -> Int? {
        guard let cg = image.cgImage else { return nil }
        let scale = Int(image.scale)
        let width = min(cg.width, 300 * scale), height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        for y in (70 * scale)..<height {
            var dark = 0
            for x in 0..<width where pixels[(y * width + x) * 4] < 60 { dark += 1 }
            if dark > 20 { return y / scale }
        }
        return nil
    }

    /// Hosts the view with its safe areas (the tab bar and navigation bar lay out
    /// against them) and attaches the render
    private func render<V: View>(_ view: V, size: CGSize, name: String) -> UIImage {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "render-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        return image
    }
}
