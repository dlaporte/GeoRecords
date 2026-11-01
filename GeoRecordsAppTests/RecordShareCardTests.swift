//
//  RecordShareCardTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
import UIKit
@testable import GeoRecords

struct RecordShareCardTests {

    // The share image is a fixed 540 pt square rendered at 3x
    @MainActor
    @Test func shareCardRendersAtThreeTimesScale() async throws {
        let record = RecordDetail(value: 71.17, timestamp: noon(2026, 10, 10),
                                  coordinate: CLLocationCoordinate2D(latitude: 71.17, longitude: 25.78),
                                  altitude: 0, locationName: "Nordkapp, Norway", recordType: RecordType.north.rawValue)
        let image = try #require(RecordShareCardView.render(record: record, unitSystem: .imperial, homeCoordinate: nil, photo: nil))
        #expect(image.size.width * image.scale == 1620)
        #expect(image.size.height * image.scale == 1620)
    }
}
