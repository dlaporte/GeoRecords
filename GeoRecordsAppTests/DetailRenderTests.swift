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

    private func record(withPhoto: Bool) -> RecordDetail {
        RecordDetail(value: -151.7411, timestamp: Date(timeIntervalSince1970: 1_002_975_360),
                     coordinate: CLLocationCoordinate2D(latitude: -16.5003, longitude: -151.7411),
                     altitude: 4, locationName: "French Polynesia, French Polynesia",
                     recordType: RecordType.west.rawValue, timeFrame: .allTime,
                     photoData: withPhoto ? SeedPhoto.jpeg(titled: "French Polynesia") : nil,
                     dateAdded: Date(timeIntervalSince1970: 1_767_945_600), source: .photo)
    }

    private func region() -> RecordDetail {
        RecordDetail(value: 1_503_460_800, timestamp: Date(timeIntervalSince1970: 1_503_460_800),
                     coordinate: CLLocationCoordinate2D(latitude: 36.1699, longitude: -115.1398),
                     altitude: 0, locationName: "California", recordType: RecordType.state.rawValue,
                     timeFrame: .allTime, photoData: SeedPhoto.jpeg(titled: "California"),
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
    }
}
