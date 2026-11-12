//
//  DetailRenderTests.swift
//  GeoRecordsTests
//
//  Renders a record's detail at the sizes the design was drawn for and attaches the
//  PNGs: the pushed page (iPhone, the Duo folded and upright), the split view's
//  column with the photo beside the rows (iPads in landscape) and above them (iPad
//  portrait, the Duo in landscape, a book-pose page), plus History's wide column and
//  the no-photo page, where the map takes the top slot. Nothing is asserted beyond
//  the render existing: the attachments are for eyeballing. Export with
//  `xcrun xcresulttool export attachments`.
//

import XCTest
import SwiftUI
import CoreLocation
@testable import GeoRecords

@MainActor
final class DetailRenderTests: XCTestCase {

    private func record(withPhoto: Bool, timeFrame: TimeFrame = .allTime,
                        photoSize: CGSize = CGSize(width: 1600, height: 1200)) -> RecordDetail {
        RecordDetail(value: -151.7411, timestamp: Date(timeIntervalSince1970: 1_002_975_360),
                     coordinate: CLLocationCoordinate2D(latitude: -16.5003, longitude: -151.7411),
                     altitude: 4, locationName: "French Polynesia, French Polynesia",
                     recordType: RecordType.west.rawValue, timeFrame: timeFrame,
                     photoData: withPhoto ? SeedPhoto.jpeg(titled: "French Polynesia", size: photoSize) : nil,
                     dateAdded: Date(timeIntervalSince1970: 1_767_945_600), source: .photo)
    }

    private func region(withPhoto: Bool = true) -> RecordDetail {
        RecordDetail(value: 1_503_460_800, timestamp: Date(timeIntervalSince1970: 1_503_460_800),
                     coordinate: CLLocationCoordinate2D(latitude: 36.1699, longitude: -115.1398),
                     altitude: 0, locationName: "California", recordType: RecordType.state.rawValue,
                     timeFrame: .allTime, photoData: withPhoto ? SeedPhoto.jpeg(titled: "California") : nil,
                     regionCode: "US-CA", source: .photo)
    }

    private func page<V: View>(_ view: V) -> some View {
        NavigationStack { view }
            .environmentObject(SettingsManager.shared)
            .environmentObject(RecordManager.shared)
    }

    private func column<V: View>(_ view: V) -> some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List { Text("row") }.navigationTitle("Records")
        } detail: {
            view
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(SettingsManager.shared)
        .environmentObject(RecordManager.shared)
    }

    private var mapStandIn: AnyView {
        AnyView(Color(red: 0.06, green: 0.1, blue: 0.16).overlay(Text("map").foregroundColor(.gray)))
    }

    func testPagesAtPhoneAndDuoSizes() throws {
        let record = record(withPhoto: true)
        attach(page(RecordDetailPager(records: [record], initialIndex: 0)), size: CGSize(width: 402, height: 874), name: "page-iphone")
        attach(page(RecordDetailPager(records: [record], initialIndex: 0)), size: CGSize(width: 382, height: 644), name: "page-duo-folded")
        attach(page(RecordDetailPager(records: [record], initialIndex: 0)), size: CGSize(width: 669, height: 951), name: "page-duo-upright")
        attach(page(RecordDetailView(record: region())), size: CGSize(width: 402, height: 874), name: "page-iphone-region")
        attach(page(RecordDetailView(record: self.record(withPhoto: false))), size: CGSize(width: 402, height: 874), name: "page-iphone-no-photo")
        attach(page(RecordDetailView(record: region())), size: CGSize(width: 669, height: 951), name: "page-duo-upright-region")
        attach(page(RecordDetailView(record: region(withPhoto: false))), size: CGSize(width: 669, height: 951), name: "page-duo-upright-region-no-photo")
        attach(page(RecordDetailView(record: region(withPhoto: false))), size: CGSize(width: 382, height: 644), name: "page-duo-folded-region-no-photo")
    }

    func testColumnsAtPadAndDuoSizes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "needs regular width: run on an iPad simulator")
        let record = record(withPhoto: true)
        let detail = RecordDetailView(record: record, style: .column, map: mapStandIn)
        attach(column(detail), size: CGSize(width: 1376, height: 1032), name: "column-pad13-landscape")
        attach(column(detail), size: CGSize(width: 1194, height: 834), name: "column-pad11-landscape")
        attach(column(detail), size: CGSize(width: 1032, height: 1376), name: "column-pad13-portrait")
        attach(column(detail), size: CGSize(width: 868, height: 669), name: "column-duo-landscape")
        attach(column(RecordDetailView(record: region(), style: .column, map: mapStandIn)), size: CGSize(width: 1376, height: 1032), name: "column-pad13-landscape-region")
        attach(column(RecordDetailView(record: self.record(withPhoto: false), style: .column, map: mapStandIn)), size: CGSize(width: 1376, height: 1032), name: "column-pad13-landscape-no-photo")
        attach(column(RecordDetailView(record: region(), style: .column, map: mapStandIn)), size: CGSize(width: 868, height: 669), name: "column-duo-landscape-region")
        attach(column(RecordDetailView(record: region(withPhoto: false), style: .column, map: mapStandIn)), size: CGSize(width: 868, height: 669), name: "column-duo-landscape-region-no-photo")
        attach(column(RecordDetailView(record: region(withPhoto: false), style: .column, map: mapStandIn)), size: CGSize(width: 834, height: 1194), name: "column-pad11-portrait-region-no-photo")
    }

    /// The heading's timeframe badge at each timeframe, to measure where its circle lands
    func testHeadingBadgeAtEachTimeframe() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "needs regular width: run on an iPad simulator")
        for (name, timeFrame) in [("lifetime", TimeFrame.allTime), ("yearly", .year), ("monthly", .month)] {
            let detail = RecordDetailView(record: record(withPhoto: true, timeFrame: timeFrame), style: .column, map: mapStandIn)
            attach(column(detail), size: CGSize(width: 868, height: 669), name: "badge-column-\(name)")
        }
    }

    /// Real photos of odd shapes, drawn after the photo task has landed: a portrait
    /// phone photo and a panorama, on the pages and in both panel styles
    func testPhotoFramesAtOddAspectRatios() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "needs regular width: run on an iPad simulator")
        let shapes = [("portrait", CGSize(width: 1200, height: 1600)), ("panorama", CGSize(width: 2400, height: 800))]
        for (shape, size) in shapes {
            let record = record(withPhoto: true, photoSize: size)
            attach(page(RecordDetailView(record: record)), size: CGSize(width: 382, height: 644), name: "photo-\(shape)-page-folded", settle: 0.6)
            attach(page(RecordDetailView(record: record)), size: CGSize(width: 669, height: 951), name: "photo-\(shape)-page-upright", settle: 0.6)
            attach(column(RecordDetailView(record: record, style: .column, map: mapStandIn)), size: CGSize(width: 868, height: 669), name: "photo-\(shape)-column-duo", settle: 0.6)
            attach(column(RecordDetailView(record: record, style: .column, map: mapStandIn)), size: CGSize(width: 1376, height: 1032), name: "photo-\(shape)-column-pad13", settle: 0.6)
        }
    }
}
